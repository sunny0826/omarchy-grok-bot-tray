#!/usr/bin/env bash
# Supervising launcher for grok-bot.service — the service's main process.
# Replaces systemd's Restart=always so respawning is update-aware:
#   - never starts a second instance (waits out any foreign instance, e.g.
#     one relaunched by the app's self-updater)
#   - cools down longer when the app dir changed (self-update replaced files)
set -uo pipefail

# App install location: GROKBOT_APP_DIR wins; default to ~/.local/opt (FPM
# extract layout), fall back to the deb's system-wide /opt path.
APP_DIR="${GROKBOT_APP_DIR:-$HOME/.local/opt/Grok Bot}"
[[ -x "$APP_DIR/grok-bot" ]] || APP_DIR="/opt/Grok Bot"
REAL="$APP_DIR/grok-bot"
WIN_CLASS="${GROKBOT_WIN_CLASS:-grok-bot}"

stamp() {
  stat -c %Y "$APP_DIR/resources/app.asar" 2>/dev/null || echo 0
}

while true; do
  # A foreign instance exists (manual launch or updater relaunch): don't
  # fight it for the single-instance lock — wait for it to exit, then take
  # over. This keeps exactly one grok-bot alive at all times.
  if pgrep -x "$WIN_CLASS" >/dev/null 2>&1; then
    while pgrep -x "$WIN_CLASS" >/dev/null 2>&1; do sleep 1; done
    continue
  fi

  before="$(stamp)"
  # Hide the window into the tray once it maps. This replaces the service's
  # ExecStartPost: that only fires when the service starts, not on respawns
  # happening inside this loop. autohide.sh detaches immediately and is
  # idempotent (no-ops once the window sits in the tray workspace).
  "$(dirname "$0")/autohide.sh"
  "$REAL" || true
  after="$(stamp)"

  # If the app files changed under us, this was likely a self-update — give
  # the updater room to finish before relaunching.
  if [[ "$after" != "$before" ]]; then
    sleep 5
  else
    sleep 2
  fi
done
