#!/usr/bin/env bash
# Grok Bot tray control — the single entry point for start/stop/window ops.
# Launches and quits always go through systemd so the app's single-instance
# lock is never contended (see plugin README, "single-instance rule").
set -euo pipefail

WIN_CLASS="${GROKBOT_WIN_CLASS:-grok-bot}"   # window class == binary name
TRAY_WS="special:grok-tray"
UNIT="grok-bot.service"
UPDATE_TIMER="grok-bot-update.timer"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/grok-bot-tray"
LAST_WS_FILE="$STATE_DIR/last-ws"

win() {
  hyprctl clients -j 2>/dev/null | jq -c --arg c "$WIN_CLASS" '[.[] | select(.class == $c)][0] // empty'
}

proc_running() {
  pgrep -x "$WIN_CLASS" >/dev/null 2>&1
}

# Hyprland 0.56 (Omarchy) evaluates dispatcher args as Lua expressions — the
# classic `hyprctl dispatch movetoworkspacesilent ws,address:...` syntax no
# longer works. All window ops go through `hyprctl eval` with the hl.* API.
eval_lua() {
  hyprctl eval "$1" >/dev/null
}

# Kill every grok-bot process and wait until they are really gone. Electron
# shuts down slowly on SIGTERM (5-10s), so escalate to SIGKILL after 4s.
kill_until_gone() {
  local _
  pkill -x "$WIN_CLASS" 2>/dev/null || true
  for _ in $(seq 1 8); do
    if ! proc_running; then return 0; fi
    sleep 0.5
  done
  pkill -9 -x "$WIN_CLASS" 2>/dev/null || true
  for _ in $(seq 1 10); do
    if ! proc_running; then return 0; fi
    sleep 0.5
  done
  return 1
}

cmd_status() {
  local w ws
  w="$(win)"
  if [[ -n "$w" ]]; then
    ws="$(jq -r '.workspace.name' <<<"$w")"
    if [[ "$ws" == "$TRAY_WS" ]]; then
      echo running-hidden
    else
      echo running-visible
    fi
  elif proc_running; then
    echo starting
  else
    echo stopped
  fi
}

cmd_hide() {
  local w addr ws
  w="$(win)"
  if [[ -z "$w" ]]; then return 0; fi
  ws="$(jq -r '.workspace.name' <<<"$w")"
  if [[ "$ws" == "$TRAY_WS" ]]; then return 0; fi
  mkdir -p "$STATE_DIR"
  jq -r '.workspace.id' <<<"$w" >"$LAST_WS_FILE"
  addr="$(jq -r '.address' <<<"$w")"
  # window.move acts on the focused window, so focus the target first and
  # restore the previous focus afterwards (unless it *was* the target).
  local prev
  prev="$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')"
  if [[ "$prev" == "$addr" ]]; then prev=""; fi
  eval_lua "(function() hl.dispatch(hl.dsp.focus({window='address:$addr'})); hl.dispatch(hl.dsp.window.move({workspace='$TRAY_WS', follow=false})); if '$prev' ~= '' then hl.dispatch(hl.dsp.focus({window='address:$prev'})) end end)()"
}

cmd_show() {
  local w addr target
  w="$(win)"
  if [[ -z "$w" ]]; then return 0; fi
  addr="$(jq -r '.address' <<<"$w")"
  target=""
  if [[ -f "$LAST_WS_FILE" ]]; then target="$(cat "$LAST_WS_FILE")"; fi
  if [[ ! "$target" =~ ^[0-9]+$ ]]; then
    # Fall back to the active workspace (workspace 1 if a special is on top).
    target="$(hyprctl activeworkspace -j | jq -r 'if (.name | startswith("special:")) then "1" else (.id | tostring) end')"
  fi
  # follow=true moves focus along with the window.
  eval_lua "(function() hl.dispatch(hl.dsp.focus({window='address:$addr'})); hl.dispatch(hl.dsp.window.move({workspace=$target})) end)()"
}

cmd_start() {
  # Idempotent: sweep up a manually started instance first — it would hold
  # the single-instance lock and keep the service instance from ever mapping
  # a window (the supervising wrapper waits out foreign instances).
  if ! systemctl --user is-active --quiet "$UNIT" && proc_running; then
    kill_until_gone || true
  fi
  systemctl --user start "$UNIT"
}

cmd_open() {
  # "App icon clicked": make sure it runs, then bring the window to me.
  cmd_start
  local _
  for _ in $(seq 1 30); do
    case "$(cmd_status)" in
      running-hidden | running-visible)
        cmd_show
        return 0
        ;;
    esac
    sleep 0.5
  done
}

cmd_quit() {
  systemctl --user stop "$UNIT" 2>/dev/null || true
  # Sweep up any manually started instance so nothing survives.
  kill_until_gone
}

cmd_toggle() {
  case "$(cmd_status)" in
    stopped) cmd_start ;;
    running-hidden) cmd_show ;;
    *) cmd_hide ;;
  esac
}

cmd_autoupdate_status() {
  # The user choice for daily auto-updates is persisted as the enable state
  # of grok-bot-update.timer (survives reboots and plugin re-installs). It
  # only counts as "on" when the timer is also running — an enabled but
  # inactive timer would silently skip the daily checks.
  if systemctl --user is-enabled --quiet "$UPDATE_TIMER" 2>/dev/null \
    && systemctl --user is-active --quiet "$UPDATE_TIMER" 2>/dev/null; then
    echo on
  else
    echo off
  fi
}

cmd_autoupdate_toggle() {
  if [[ "$(cmd_autoupdate_status)" == "on" ]]; then
    systemctl --user disable --now "$UPDATE_TIMER" 2>/dev/null || true
    echo "auto-update off"
  else
    systemctl --user enable --now "$UPDATE_TIMER"
    echo "auto-update on"
  fi
}

case "${1:-}" in
  status) cmd_status ;;
  hide) cmd_hide ;;
  show) cmd_show ;;
  start) cmd_start ;;
  open) cmd_open ;;
  quit) cmd_quit ;;
  toggle) cmd_toggle ;;
  autoupdate-status) cmd_autoupdate_status ;;
  autoupdate-toggle) cmd_autoupdate_toggle ;;
  *) echo "usage: $0 {status|toggle|show|hide|start|open|quit|autoupdate-status|autoupdate-toggle}" >&2; exit 2 ;;
esac
