# TTRC Admin (phone app)

Simple phone-first admin for The Tactical Rabbi. Demo data only. No passwords, tokens or customer data are stored in this repository.

- `index.html`, `manifest.webmanifest`, `sw.js`, `icons/` : the installable app.
- `server/m-setup.sh` : installs the app at https://stage.thetacticalrabbi.com/m/ (staging only). It backs up first, validates Nginx before restarting, and restores automatically on failure. `bash m-setup.sh undo` reverts.
