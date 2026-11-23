# Changelog

Release notes shown in MacPilot's update window (one `## version` section per release).

## 0.32.0
- **Developer cleanup:** Developer → Cleanup finds node_modules, Xcode DerivedData/Archives/DeviceSupport, simulator caches, unavailable simulators, Docker leftovers and package-manager caches, with sizes, age filters and Reveal in Finder.
- Safe by default: everything is confirmed and goes to the Trash; only caches can be deleted permanently (second confirmation); symlinks and paths outside the scanned folders are refused; active projects are skipped; commands are shown before they run; every cleanup is audit-logged.
- Dashboard “GB reclaimable” card, ⌥K “how much can I free?”, Telegram `/cleanup` (caches only, with Approve), agent tools `scan_cleanup` / `run_cleanup`, optional monthly reminder.

## 0.31.0
- **First-run setup:** a guided window for your AI provider, permissions (with live status), calendar, features, Telegram and updates. Every step can be skipped; quitting resumes where you left off.
- Reopen it from Settings → General, the menu bar or ⌥K “Setup”. The dashboard shows “Setup: 5/7 done” until the required steps are finished.

## 0.30.0
- **Auto-updates:** MacPilot checks for new versions daily and installs them when you say so (Sparkle 2, EdDSA-signed updates).
- **Check for Updates…** in the menu bar, ⌥K and Settings → General; Telegram `/version`.
- Optional: download and install updates automatically.

## 0.29.0
- Port killer: see what's listening and stop it safely (Developer → Ports, ⌥K, Telegram, agent).
