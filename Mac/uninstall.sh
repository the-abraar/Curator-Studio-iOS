#!/bin/bash
# Removes the Curator Studio launch agent and daemon files.
# Your downloaded media and config are left alone unless you pass --purge.

set -euo pipefail
AGENT_LABEL="com.blankframe.curatorstudio.daemon"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
rm -f "$AGENT_PLIST"
rm -f "$HOME/.curator-studio/curator_daemon.py"
echo "Launch agent removed."

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/.curator-studio"
  echo "Config, token and job history deleted. Media files untouched."
fi
