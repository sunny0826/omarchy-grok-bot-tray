#!/usr/bin/env bash
# Wait for the Grok Bot window to map, then hide it into the tray workspace.
# Used as ExecStartPost=; detaches immediately so service startup is not delayed.
set -euo pipefail

CTL="$(dirname "$0")/grokbot-ctl.sh"

(
  for _ in $(seq 1 60); do
    case "$("$CTL" status)" in
      running-hidden) exit 0 ;;
      running-visible) "$CTL" hide && exit 0 ;;
    esac
    sleep 0.5
  done
) >/dev/null 2>&1 &
