#!/usr/bin/env bash
# Installs the systemd user units for Grok Bot Tray, pointing them at this
# plugin's actual location, then enables them. Run it manually after
# `omarchy plugin add` — the marketplace never executes plugin code for you.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
SHIM="$HOME/.local/bin/grok-bot"

install_units() {
  echo "Installing units: $PLUGIN_DIR/systemd/ -> $UNIT_DIR/"
  mkdir -p "$UNIT_DIR"
  local f
  for f in grok-bot.service grok-bot-update.service grok-bot-update.timer; do
    if [[ ! -f "$PLUGIN_DIR/systemd/$f" ]]; then
      echo "error: missing systemd/$f" >&2
      exit 1
    fi
    sed "s|@PLUGIN_DIR@|$PLUGIN_DIR|g" "$PLUGIN_DIR/systemd/$f" >"$UNIT_DIR/$f"
    echo "  wrote ~${UNIT_DIR#"$HOME"}/$f"
  done
  systemctl --user daemon-reload
  systemctl --user enable grok-bot-update.timer
  # restart (not enable --now) so a plugin path change takes effect on an
  # already-running supervisor; first start parks Grok Bot via autohide.sh.
  systemctl --user enable grok-bot.service
  systemctl --user restart grok-bot.service
  echo "Enabled: grok-bot.service (supervisor) + grok-bot-update.timer (daily)"
}

install_shim() {
  # Optional: only useful when your Grok Bot .desktop points at
  # ~/.local/bin/grok-bot. Plain clicks then show the window instead of
  # fighting the service for the single-instance lock; deep links still work.
  if [[ -f "$SHIM" ]]; then
    cp "$SHIM" "$SHIM.bak.$(date +%s)"
    echo "Backed up existing $SHIM"
  fi
  cat >"$SHIM" <<'EOF'
#!/usr/bin/env bash
# Launcher shim (installed by omarchy-grok-bot-tray): plain clicks show the
# window; calls with arguments (deep links) forward to the real binary.
if [[ $# -gt 0 ]]; then
  CTL="$HOME/.config/omarchy/plugins/sunny0826.grok-bot-tray/scripts/grokbot-ctl.sh"
  [[ -x "$CTL" ]] && "$CTL" open >/dev/null 2>&1 || true
  exec "$HOME/.local/opt/Grok Bot/grok-bot" "$@"
fi
exec "$HOME/.config/omarchy/plugins/sunny0826.grok-bot-tray/scripts/grokbot-ctl.sh" open
EOF
  chmod +x "$SHIM"
  echo "Installed launcher shim at $SHIM"
}

uninstall() {
  systemctl --user disable --now grok-bot.service grok-bot-update.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/grok-bot.service" "$UNIT_DIR/grok-bot-update.service" "$UNIT_DIR/grok-bot-update.timer"
  systemctl --user daemon-reload
  # Stop Grok Bot cleanly too (leaves the app stopped; restart it via the
  # widget or `omarchy launch` afterwards if you keep the plugin).
  systemctl --user stop grok-bot.service 2>/dev/null || true
  echo "Units removed. The plugin itself: omarchy plugin remove sunny0826.grok-bot-tray"
  echo "Launcher shim restored from its newest .bak (remove it manually if unwanted)."
}

case "${1:-}" in
  "") install_units ;;
  --with-launcher) install_units && install_shim ;;
  --uninstall) uninstall ;;
  *)
    echo "usage: $0 [--with-launcher | --uninstall]" >&2
    exit 2
    ;;
esac
