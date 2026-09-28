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
  # marker). Symlinks never count as ours: a redirect would follow them
  # and touch an unrelated target. Anything else must never be
  # overwritten or removed.
  [[ -f "$1" && ! -L "$1" ]] && grep -qE 'Managed-by: sunny0826\.grok-bot-tray|grok-bot-tray/scripts' "$1"
}

install_units() {
  echo "Installing units: $PLUGIN_DIR/systemd/ -> $UNIT_DIR/"
  mkdir -p "$UNIT_DIR"
  local f target tmp keep_autoupdate_off=false
  # Respect an earlier user choice: if our update timer already exists and is
  # disabled, a re-install keeps daily auto-updates off (the menu switch is
  # the user's control) instead of re-enabling the default.
  if [[ -f "$UNIT_DIR/grok-bot-update.timer" ]] && is_managed "$UNIT_DIR/grok-bot-update.timer" \
    && ! systemctl --user is-enabled --quiet grok-bot-update.timer 2>/dev/null; then
    keep_autoupdate_off=true
  fi
  # Pass 1: refuse up front if ANY existing entry is not ours (including
  # dangling symlinks), so a late refusal can never leave a half-installed
  # set behind and no write ever follows a planted link.
  for f in grok-bot.service grok-bot-update.service grok-bot-update.timer; do
    if [[ ! -f "$PLUGIN_DIR/systemd/$f" ]]; then
      echo "error: missing systemd/$f" >&2
      exit 1
    fi
    target="$UNIT_DIR/$f"
    if [[ -e "$target" || -L "$target" ]] && ! is_managed "$target"; then
      echo "error: $target exists and is not managed by this plugin" >&2
      echo "       refusing to overwrite it; inspect/remove it, then re-run" >&2
      exit 1
    fi
  done
  # Pass 2: all clear — render every unit with an ownership marker. Each
  # unit is created exclusively at an unpredictable same-directory name
  # and renamed into place, so a redirect can never follow a link either.
  for f in grok-bot.service grok-bot-update.service grok-bot-update.timer; do
    target="$UNIT_DIR/$f"
    tmp="$(mktemp "$UNIT_DIR/.$f.XXXXXXXX")"
    { echo "# Managed-by: sunny0826.grok-bot-tray"
      sed "s|@PLUGIN_DIR@|$PLUGIN_DIR|g" "$PLUGIN_DIR/systemd/$f"; } >"$tmp"
    mv -f "$tmp" "$target"
    echo "  wrote ~${UNIT_DIR#"$HOME"}/$f"
  done
  systemctl --user daemon-reload
  if [[ "$keep_autoupdate_off" == true ]]; then
    echo "  auto-update kept off (your earlier choice via the menu switch)"
  else
    # Default: daily auto-update is on.
    systemctl --user enable grok-bot-update.timer
  fi
  # restart (not enable --now) so a plugin path change takes effect on an
  # already-running supervisor; first start parks Grok Bot via autohide.sh.
  systemctl --user enable grok-bot.service
  systemctl --user restart grok-bot.service
  if [[ "$keep_autoupdate_off" == true ]]; then
    echo "Enabled: grok-bot.service (supervisor); auto-update: off (kept your choice)"
  else
    echo "Enabled: grok-bot.service (supervisor) + grok-bot-update.timer (daily)"
  fi
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
  # Ownership-safe: never write through a symlink (that would clobber its
  # unrelated target). Any entry that is not our own shim is moved aside
  # intact first — links included, their targets untouched. Every new name
  # is reserved with mktemp: exclusive creation at an unpredictable
  # same-directory name, so nothing pre-planted can occupy it and repeated
  # runs can never overwrite an earlier backup.
  local backup tmp
  if [[ -d "$SHIM" && ! -L "$SHIM" ]]; then
    echo "error: $SHIM is a directory" >&2
    echo "       refusing to replace it; inspect/remove it, then re-run" >&2
    exit 1
  fi
  if [[ -e "$SHIM" || -L "$SHIM" ]] && ! shim_is_managed "$SHIM"; then
    backup="$(mktemp "$SHIM.bak.$(date +%s).XXXXXXXX")"
    mv -f "$SHIM" "$backup"
    echo "Backed up existing $SHIM -> ~${backup#"$HOME"}"
  fi
  tmp="$(mktemp "$SHIM.new.XXXXXXXX")"
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
