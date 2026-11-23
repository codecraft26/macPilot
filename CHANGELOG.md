# Changelog

Release notes shown in MacPilot's update window (one `## version` section per release).

## 0.33.3
- **Fix:** a follow-up in the Agent tab opened a new chat. The Agent tab now has chats: replying continues the selected chat, and the agent gets the earlier messages, tool calls and answers as context (newest kept when trimming). Approvals and budgets still apply to each message.
- The view no longer jumps to whichever task is running; it stays on your chat and scrolls to the bottom. New chat (⌘N), rename from the right-click menu, Retry re-runs the last message in the same chat.
- Telegram: messages continue your current chat; `/new` or 30 minutes of quiet starts a new one. Existing tasks show as single-message chats.

## 0.33.2
- Settings → Agent → Telegram shows the next setup step under “Bot: Off” (paste the token, turn on Connect the bot, pair a phone).

## 0.33.1
- **Fix:** the agent asked for an Anthropic (Claude) API key even when Claude via Amazon Bedrock was set up. The agent — and memory open loops, search Ask and smart reminders, which share its settings — now runs on the provider you configured: your default first, then Bedrock, Anthropic, OpenAI, Ollama.
- A provider you picked in Settings → Agent is never switched; without credentials you're offered the configured one with one click. Existing installs stuck on Anthropic without a key move to Bedrock once, with a notice.
- Settings → Agent → Test connection; the setup wizard recognises saved Bedrock credentials. Labels: “Claude (Bedrock)” and “Claude (Anthropic API)”.

## 0.33.0
- **Network speed and CPU beside the notch**, on by default: ↓/↑ on the left, CPU % on the right (orange above 80%). It steps aside for recordings, music and alerts.
- Click it for 60-second graphs, per-core bars, memory, the top 5 processes and a speed test (also in the menu bar: System Monitor…).
- Macs without a notch show it in the menu bar (network, CPU or both). Settings → Notch: separate toggles, units (Auto / MB/s / Mbps), 1 s or 2 s updates.
- Sampling uses about 0.01% CPU and pauses while the screen is locked or asleep.

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
