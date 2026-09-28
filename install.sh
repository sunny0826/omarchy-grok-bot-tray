#!/usr/bin/env bash
# Installs the systemd user units for Grok Bot Tray, pointing them at this
# plugin's actual location, then enables them. Run it manually after
# `omarchy plugin add` — the marketplace never executes plugin code for you.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
SHIM="$HOME/.local/bin/grok-bot"

is_managed() {
  # A unit file belongs to this plugin when it carries our marker (new
  # installs) or points at this plugin's scripts (installs predating the
  # marker). Anything else must never be overwritten or removed.
  grep -qE 'Managed-by: sunny0826\.grok-bot-tray|grok-bot-tray/scripts' "$1"
}

install_units() {
  echo "Installing units: $PLUGIN_DIR/systemd/ -> $UNIT_DIR/"
  mkdir -p "$UNIT_DIR"
  local f target
  # Pass 1: refuse up front if ANY existing unit is not ours, so a late
  # refusal can never leave a half-installed set behind.
  for f in grok-bot.service grok-bot-update.service grok-bot-update.timer; do
    if [[ ! -f "$PLUGIN_DIR/systemd/$f" ]]; then
      echo "error: missing systemd/$f" >&2
      exit 1
    fi
    target="$UNIT_DIR/$f"
    if [[ -f "$target" ]] && ! is_managed "$target"; then
      echo "error: $target exists and is not managed by this plugin" >&2
      echo "       refusing to overwrite it; inspect/remove it, then re-run" >&2
      exit 1
    fi
  done
  # Pass 2: all clear — render every unit with an ownership marker.
  for f in grok-bot.service grok-bot-update.service grok-bot-update.timer; do
    target="$UNIT_DIR/$f"
    { echo "# Managed-by: sunny0826.grok-bot-tray"
      sed "s|@PLUGIN_DIR@|$PLUGIN_DIR|g" "$PLUGIN_DIR/systemd/$f"; } >"$target"
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

shim_is_managed() {
  # The shim we install carries this marker. A symlink never counts as
  # ours: a plain redirect would follow it and overwrite its target.
  [[ -f "$1" && ! -L "$1" ]] && grep -q 'installed by omarchy-grok-bot-tray' "$1"
}

install_shim() {
  # Optional: only useful when your Grok Bot .desktop points at
  # ~/.local/bin/grok-bot. Plain clicks then show the window instead of
  # fighting the service for the single-instance lock; deep links still work.
  #
  # Ownership-safe: never write through an existing symlink (that would
  # clobber its unrelated target). Any entry that is not our own shim is
  # moved aside intact first — links included, their targets untouched.
  # Collision-safe: the backup name is timestamp + pid and never reused,
  # so repeated runs can never overwrite an earlier backup.
  local backup n=0 tmp
  if [[ -d "$SHIM" && ! -L "$SHIM" ]]; then
    echo "error: $SHIM is a directory" >&2
    echo "       refusing to replace it; inspect/remove it, then re-run" >&2
    exit 1
  fi
  if [[ -e "$SHIM" || -L "$SHIM" ]] && ! shim_is_managed "$SHIM"; then
    backup="$SHIM.bak.$(date +%s).$"
    while [[ -e "$backup" || -L "$backup" ]]; do
      n=$((n + 1))
      backup="$SHIM.bak.$(date +%s).$.$n"
    done
    mv "$SHIM" "$backup"
    echo "Backed up existing $SHIM -> ~${backup#"$HOME"}"
  fi
  # Write via rename: even a symlink planted in the meantime is replaced
  # as a directory entry, never written through.
  tmp="$SHIM.new.$"
  cat >"$tmp" <<'EOF'
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
  chmod +x "$tmp"
  mv -f "$tmp" "$SHIM"
  echo "Installed launcher shim at $SHIM"
}

uninstall() {
  local f target
  # Ownership first: a unit's lifecycle may be touched only when the unit
  # file in $UNIT_DIR belongs to this plugin. Acting on the bare unit name
  # unconditionally would stop/disable an unrelated same-named service —
  # even one whose unit file lives in another unit directory entirely
  # (e.g. /usr/lib/systemd/user). `disable --now` covers the clean stop.
  for f in grok-bot.service grok-bot-update.timer; do
    target="$UNIT_DIR/$f"
    if [[ -f "$target" ]] && is_managed "$target"; then
      systemctl --user disable --now "$f" 2>/dev/null || true
    fi
  done
  for f in grok-bot.service grok-bot-update.service grok-bot-update.timer; do
    target="$UNIT_DIR/$f"
    [[ -f "$target" ]] || continue
    if is_managed "$target"; then
      rm -f "$target"
      echo "  removed ~${UNIT_DIR#"$HOME"}/$f"
    else
      echo "  skipped $target (not managed by this plugin)"
    fi
  done
  systemctl --user daemon-reload
  echo "Units removed. The plugin itself: omarchy plugin remove sunny0826.grok-bot-tray"
  echo "Launcher shim left in place; restore from ~${SHIM#"$HOME"}.bak.* or remove it manually."
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
