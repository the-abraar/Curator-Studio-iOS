#!/bin/bash
#
# Curator Studio — Mac side installer.
#
#   ./install.sh
#
# Installs the tools the daemon needs, drops it in ~/.curator-studio, and
# registers a launchd agent so it starts with your Mac and restarts if it
# crashes. Safe to re-run; it just updates things in place.

set -euo pipefail

BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RESET=$'\033[0m'
say()  { echo "${BLUE}==>${RESET} $*"; }
ok()   { echo "${GREEN} ✓ ${RESET} $*"; }
warn() { echo "${YELLOW} ! ${RESET} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.curator-studio"
AGENT_LABEL="com.blankframe.curatorstudio.daemon"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
LIBRARY_ROOT="${CURATOR_LIBRARY:-$HOME/CuratorStudio}"

# ---------------------------------------------------------------- dependencies

say "Checking dependencies"

if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew is not installed."
  echo "    Install it from https://brew.sh and run this script again."
  exit 1
fi

for pkg in yt-dlp ffmpeg atomicparsley; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    ok "$pkg already installed"
  else
    say "Installing $pkg"
    brew install "$pkg"
  fi
done

say "Updating yt-dlp (YouTube changes often — keep this fresh)"
brew upgrade yt-dlp >/dev/null 2>&1 || true
ok "yt-dlp $(yt-dlp --version 2>/dev/null || echo '?')"

# ---------------------------------------------------------------- files

say "Installing daemon into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/curator_daemon.py" "$INSTALL_DIR/curator_daemon.py"
chmod +x "$INSTALL_DIR/curator_daemon.py"

mkdir -p "$LIBRARY_ROOT"
for folder in "Songs" "Guitar Lessons" "Bike Stuff" "Learn Stuff/AI" "Learn Stuff/Programming" "Learn Stuff/German" "Randoms"; do
  mkdir -p "$LIBRARY_ROOT/$folder"
done
ok "Library root: $LIBRARY_ROOT"

# Generates the config (and a token) on first run.
python3 "$INSTALL_DIR/curator_daemon.py" --token >/dev/null 2>&1 || true

python3 - "$LIBRARY_ROOT" <<'PY'
import json, os, sys
path = os.path.expanduser("~/.curator-studio/config.json")
config = {}
if os.path.exists(path):
    with open(path) as handle:
        config = json.load(handle)
config["library_root"] = sys.argv[1]
with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
PY

# ---------------------------------------------------------------- launchd

say "Registering the launch agent"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$INSTALL_DIR/curator_daemon.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/daemon.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
ok "Agent loaded"

sleep 2

# ---------------------------------------------------------------- summary

echo
say "Pairing details for the iPhone app"
python3 "$INSTALL_DIR/curator_daemon.py" --token
echo
say "Next steps"
cat <<'NEXT'
  1. On the iPhone: Curator Studio → Inbox → Connect to Mac.
     It should find this Mac by itself; otherwise type the host and token above.

  2. Optional — Telegram, so you can send links from anywhere:
       a. Message @BotFather on Telegram, send /newbot, follow the prompts.
       b. Paste the bot token into ~/.curator-studio/config.json under
          "telegram" → "bot_token".
       c. Restart:  launchctl kickstart -k gui/$(id -u)/com.blankframe.curatorstudio.daemon
       d. Message your new bot once. The first chat to talk to it gets paired.

  Useful commands:
     tail -f ~/.curator-studio/daemon.log
     python3 ~/.curator-studio/curator_daemon.py --status
     python3 ~/.curator-studio/curator_daemon.py --add "https://youtu.be/... mid Songs"
     launchctl bootout gui/$(id -u)/com.blankframe.curatorstudio.daemon   # stop
NEXT
echo
ok "Done."
