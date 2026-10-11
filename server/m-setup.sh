#!/usr/bin/env bash
# Serves the TTRC phone app at https://stage.thetacticalrabbi.com/m/ (STAGING ONLY).
# - Makes a full backup of the deploy folder first.
# - Edits only the staging HTTPS section of the Nginx template, plus one volume line in compose.edge.yml.
# - Validates the config with the developer's own "nginx -t" check BEFORE restarting anything.
# - If validation or the restart fails, it restores the backup automatically.
# Usage:  bash m-setup.sh          (install or update)
#         bash m-setup.sh undo     (restore the newest backup and restart Nginx)
set -euo pipefail

D=/opt/tactical-rabbi/deploy
ENVF=/etc/tactical-rabbi/edge.env
APP=/opt/tactical-rabbi/m
REPO_TARBALL="${REPO_TARBALL:-https://github.com/RazielCohen/ttrc-admin-app/archive/refs/heads/main.tar.gz}"
COMPOSE=(docker compose --env-file "$ENVF" -f "$D/compose.edge.yml")

restart_nginx() { "${COMPOSE[@]}" up -d --force-recreate --wait nginx; }

if [ "${1:-}" = "undo" ]; then
  BK=$(ls -dt /root/deploy-pre-m-* 2>/dev/null | head -1 || true)
  [ -n "$BK" ] || { echo "No backup found."; exit 1; }
  echo "Restoring $BK"
  cp -a "$BK/." "$D/"
  "${COMPOSE[@]}" run --rm --no-deps nginx nginx -t
  restart_nginx
  echo "UNDONE. Nginx restarted with the original settings."
  exit 0
fi

[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
[ -f "$D/compose.edge.yml" ] && [ -f "$D/nginx/templates/tls.conf.template" ] && [ -f "$ENVF" ] || { echo "Expected files are missing. Stopping."; exit 1; }

BK=/root/deploy-pre-m-$(date +%Y%m%d-%H%M%S)
cp -a "$D" "$BK"
echo "Backup saved at $BK"

mkdir -p "$APP"
echo "Downloading the app files..."
TMP=$(mktemp -d)
curl -fsSL "$REPO_TARBALL" | tar xz -C "$TMP" --strip-components=1
[ -f "$TMP/index.html" ] || { echo "index.html not found in download. Stopping."; exit 1; }
rm -rf "$APP"/*
cp -a "$TMP"/index.html "$TMP"/manifest.webmanifest "$TMP"/sw.js "$TMP"/icons "$APP"/
chmod -R a+rX "$APP"

rollback() { echo "Problem found. Restoring the backup..."; cp -a "$BK/." "$D/"; "${COMPOSE[@]}" up -d --force-recreate --wait nginx || true; echo "Restored. Nothing changed."; exit 1; }

python3 - "$D" <<'PY' || rollback
import sys,re
D=sys.argv[1]
# 1) compose.edge.yml: add the app folder as a read-only volume on the nginx service (once)
p=D+'/compose.edge.yml'; s=open(p).read()
line='      - /opt/tactical-rabbi/m:/srv/m:ro\n'
if '/srv/m:ro' not in s:
    anchor='      - letsencrypt:/etc/letsencrypt:ro\n'
    assert s.count(anchor)==1,'compose anchor not found exactly once'
    s=s.replace(anchor,anchor+line); open(p,'w').write(s)
# 2) tls.conf.template: inside the STAGING https server block only, add /m/ before "location / {"
p=D+'/nginx/templates/tls.conf.template'; s=open(p).read()
if 'location /m/' not in s:
    parts=re.split(r'(?m)^(?=server \{)',s)
    hit=[i for i,b in enumerate(parts) if 'listen 443' in b and 'server_name ${STAGING_HOST};' in b]
    assert len(hit)==1,'staging https block not found exactly once'
    b=parts[hit[0]]
    assert b.count('  location / {')==1,'location / not found exactly once'
    add=('  location = /m { return 301 /m/; }\n'
         '  location /m/ {\n    root /srv;\n    index index.html;\n    try_files $uri $uri/ /m/index.html;\n'
         '    add_header Cache-Control "no-cache" always;\n    add_header X-Content-Type-Options nosniff always;\n  }\n\n')
    parts[hit[0]]=b.replace('  location / {',add+'  location / {')
    open(p,'w').write(''.join(parts))
print('edits written')
PY

echo "Checking the new Nginx settings (nothing restarted yet)..."
"${COMPOSE[@]}" run --rm --no-deps nginx nginx -t || rollback
echo "Settings are valid. Restarting Nginx (a few seconds)..."
restart_nginx || rollback

echo "Testing..."
sleep 2
for u in https://stage.thetacticalrabbi.com/m/ https://stage.thetacticalrabbi.com/ https://thetacticalrabbi.com/; do
  printf '%s -> ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "$u" || true
done
echo "Done. Open https://stage.thetacticalrabbi.com/m/ on your phone."
echo "To undo:  bash $0 undo"
