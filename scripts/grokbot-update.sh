#!/usr/bin/env bash
# Grok Bot auto-updater for Linux (the app itself reports "此平台不支持更新").
# Fetches the official download page, compares versions, then swaps the
# FPM/deb-extracted install in ~/.local/opt with the new package.
# Fully user-level: curl + bsdtar, no sudo. Old install is kept as a
# rollback point until the new one is verified running.
set -euo pipefail

FEED_PAGE="https://cursor.com/download/bot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# App install location: GROKBOT_APP_DIR wins; default to ~/.local/opt (FPM
# extract layout), fall back to the deb's system-wide /opt path.
APP_DIR="${GROKBOT_APP_DIR:-$HOME/.local/opt/Grok Bot}"
[[ -x "$APP_DIR/grok-bot" ]] || APP_DIR="/opt/Grok Bot"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/grok-bot-tray"
WORK="$STATE_DIR/update-work"
LOG="$STATE_DIR/update.log"
CTL="$SCRIPT_DIR/grokbot-ctl.sh"

log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }
notify() { notify-send "Grok Bot Update" "$1" 2>/dev/null || true; }

local_version() {
  # Prefer the copy inside APP_DIR (copied there by this updater), then the
  # doc location a package-manager install provides.
  local f v
  for f in "$APP_DIR/changelog.gz" "/usr/share/doc/grok-bot/changelog.gz"; do
    [[ -f "$f" ]] || continue
    v="$( (zcat "$f" 2>/dev/null || true) | sed -n '1s/^grok-bot (\([^)]*\)).*/\1/p' )"
    if [[ -n "$v" ]]; then echo "$v"; return 0; fi
  done
  return 0
}

# Prints: <version>\t<url> of the latest linux/x64 .deb, or fails.
remote_latest() {
  local html url ver
  html="$(curl -fsSL --max-time 30 "$FEED_PAGE")" || return 1
  url="$(grep -aoE 'https://downloads\.cursor\.com/grokbot/[^"]*linux/x64/grok-bot_[0-9][0-9.]*_amd64\.deb' <<<"$html" | head -1)" || true
  [[ -n "$url" ]] || return 1
  ver="$(sed -E 's#.*grok-bot_([0-9][0-9.]*)_amd64\.deb#\1#' <<<"$url")"
  printf '%s\t%s\n' "$ver" "$url"
}

split_tab() {
  # Splits "ver<TAB>url" from remote_latest into REPLY_VER / REPLY_URL.
  # Uses a $'…' literal outside double quotes on purpose: inside "${x%%…}"
  # quoting it does not expand in every bash context.
  REPLY_VER="${1%%$'\t'*}"
  REPLY_URL="${1#*$'\t'}"
}

verify_digest() {
  # verify_digest <version> <pkg-path> <deb-url> — called before unpacking.
  # Order:
  #   1) official companion .sha256, when the CDN provides one (404 today)
  #   2) pinned digest from checksums.txt in this repo — a mismatch refuses
  #      the install (supply-chain protection for a mutable download URL)
  #   3) unpinned release: record the digest for audit and notify; set
  #      GROKBOT_UPDATE_VERIFY=strict to refuse unpinned releases outright.
  local ver="$1" pkg="$2" base="$3" official sum pinned
  sum="$(sha256sum "$pkg" | awk '{print $1}')"

  official="$(curl -fsSL --max-time 20 "$base.sha256" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [[ "$official" =~ ^[0-9a-f]{64}$ ]]; then
    if [[ "$official" == "$sum" ]]; then
      log "digest verified against official .sha256 ($ver)"
      return 0
    fi
    log "digest MISMATCH vs official .sha256 for $ver (expected=$official got=$sum)"
    notify "更新拒绝：$ver 与官方校验和不符"
    return 1
  fi

  pinned="$(awk -v v="$ver" '$1==v {print $2}' "$SCRIPT_DIR/checksums.txt" 2>/dev/null || true)"
  if [[ -n "$pinned" ]]; then
    if [[ "$pinned" == "$sum" ]]; then
      log "digest verified against pinned checksums.txt ($ver)"
      return 0
    fi
    log "digest MISMATCH vs pinned checksums.txt for $ver (expected=$pinned got=$sum)"
    notify "更新拒绝：$ver 校验和与仓库 pin 不符（疑似篡改）"
    return 1
  fi

  mkdir -p "$STATE_DIR"
  echo "$ver $sum" >>"$STATE_DIR/observed-digests.txt"
  log "warn: no pinned digest for $ver (sha256=$sum) — recorded to observed-digests.txt"
  notify "Grok Bot $ver 暂无 pin 校验和，已记录 sha256 供审计"
  if [[ "${GROKBOT_UPDATE_VERIFY:-}" == "strict" ]]; then
    log "refusing $ver: GROKBOT_UPDATE_VERIFY=strict and release is unpinned"
    return 1
  fi
  return 0
}

cmd_check() {
  local lv info
  lv="$(local_version)"
  info="$(remote_latest)" || { echo "check-failed (feed unreachable)"; return 1; }
  split_tab "$info"
  if [[ "$(printf '%s\n%s\n' "$lv" "$REPLY_VER" | sort -V | tail -1)" == "$lv" ]]; then
    echo "up-to-date $lv"
  else
    echo "update-available $lv -> $REPLY_VER"
  fi
}

cmd_run() {
  local lv info rv url pkg new_dir new_ver doc_changelog backup status i avail_kb
  info="$(remote_latest)" || { log "check failed: feed unreachable"; return 0; }
  split_tab "$info"
  rv="$REPLY_VER" url="$REPLY_URL"
  lv="$(local_version)"

  if [[ "$(printf '%s\n%s\n' "$lv" "$rv" | sort -V | tail -1)" == "$lv" ]]; then
    log "up to date ($lv)"
    return 0
  fi

  # Need room for the .deb + unpacked tree + rollback copy (~1 GB).
  avail_kb="$(df -Pk "$HOME" | awk 'NR==2{print $4}')"
  if (( avail_kb < 1500000 )); then
    log "skip update: only ${avail_kb}K free in \$HOME"
    notify "更新跳过：磁盘空间不足（需约 1GB）"
    return 0
  fi

  # A system-wide dpkg install (/opt) is owned by root — swap it through your
  # package manager instead of this updater.
  if [[ "$APP_DIR" == /opt/* ]]; then
    log "skip update: system install at $APP_DIR (use your package manager)"
    return 0
  fi

  log "update $lv -> $rv"
  mkdir -p "$WORK"
  pkg="$WORK/pkg.deb"

  # Download, reusing an already-fetched package (retry-friendly).
  if ! bsdtar -tf "$pkg" >/dev/null 2>&1; then
    rm -f "$pkg"
    curl -fL --max-time 900 --retry 2 -o "$pkg" "$url" || { log "download failed"; notify "更新失败：下载出错（见 update.log）"; return 1; }
  fi
  bsdtar -tf "$pkg" >/dev/null 2>&1 || { log "package is not a valid deb"; notify "更新失败：包损坏（见 update.log）"; return 1; }

  # Digest gate before anything is unpacked or swapped: a pinned release must
  # match checksums.txt (or the official .sha256 if the CDN ever ships one).
  verify_digest "$rv" "$pkg" "$url" || return 1

  # Clean previous unpack output, keep the downloaded package.
  rm -rf "$WORK/opt" "$WORK/usr" "$WORK/control.tar.xz" "$WORK/data.tar.xz" "$WORK/debian-binary"
  ( cd "$WORK" && bsdtar -xf pkg.deb && data="$(ls data.tar.* 2>/dev/null | head -1)" && [ -n "$data" ] && bsdtar -xf "$data" ) \
    || { log "unpack failed (deb or data layer)"; notify "更新失败：解包出错（见 update.log）"; return 1; }

  new_dir="$(dirname "$(find "$WORK" -path '*Grok Bot/grok-bot' -type f 2>/dev/null | head -1)")"
  [[ -n "$new_dir" && -x "$new_dir/grok-bot" ]] || { log "unpack: grok-bot binary not found"; notify "更新失败：解包结构异常（见 update.log）"; return 1; }

  # Version source: the deb ships changelog.gz under usr/share/doc, NOT inside
  # opt/. It gets copied into the install dir below to keep the existing
  # local_version() layout working (matches how this machine was installed).
  doc_changelog="$WORK/usr/share/doc/grok-bot/changelog.gz"
  new_ver=""
  if [[ -f "$doc_changelog" ]]; then
    new_ver="$( (zcat "$doc_changelog" 2>/dev/null || true) | sed -n '1s/^grok-bot (\([^)]*\)).*/\1/p' )"
  fi
  if [[ -n "$new_ver" && "$new_ver" != "$rv" ]]; then
    log "unpack version mismatch: got '$new_ver', expected '$rv'"
    notify "更新失败：版本校验不符（见 update.log）"
    return 1
  fi
  [[ -n "$new_ver" ]] || log "warn: changelog missing in package, trusting URL version $rv"

  # Swap: stop cleanly, keep the old tree as rollback, move new in. The backup
  # path is unique (timestamp + pid) so a pre-existing directory with a
  # similar name is never deleted.
  "$CTL" quit || true
  backup="$APP_DIR.bak-$lv.$(date +%s).$$"
  if [[ -n "$backup" && "$backup" != "$APP_DIR" ]]; then
    rm -rf "$backup"
  fi
  mv "$APP_DIR" "$backup" || { log "swap: mv old install failed"; "$CTL" start || true; return 1; }
  cp -f "$doc_changelog" "$new_dir/changelog.gz" 2>/dev/null || true
  mv "$new_dir" "$APP_DIR" || {
    log "swap: mv new install failed"
    mv "$backup" "$APP_DIR" || true
    "$CTL" start || true
    notify "更新失败：换位出错，已恢复原版本"
    return 1
  }

  # Verify the new build comes up; roll back if it doesn't.
  "$CTL" start || true
  status=starting
  for i in $(seq 1 30); do
    status="$("$CTL" status)"
    [[ "$status" == "running-hidden" || "$status" == "running-visible" ]] && break
    if [[ "$status" == "stopped" && $i -ge 6 ]]; then break; fi
    sleep 1
  done

  if [[ "$status" == "running-hidden" || "$status" == "running-visible" ]]; then
    log "updated $lv -> $rv (verified: $status)"
    notify "Grok Bot 已更新 $lv → $rv"
    rm -rf "$backup" "$WORK/opt" "$WORK/usr" "$WORK/control.tar.xz" "$WORK/data.tar.xz" "$WORK/debian-binary"
    return 0
  fi

  log "new build failed to start (status=$status) — rolling back to $lv"
  "$CTL" quit || true
  rm -rf "$APP_DIR"
  mv "$backup" "$APP_DIR"
  "$CTL" start || true
  notify "更新 $rv 失败，已回滚到 $lv（见 update.log）"
  return 1
}

case "${1:-check}" in
  check) cmd_check ;;
  run) cmd_run ;;
  *) echo "usage: $0 {check|run}" >&2; exit 2 ;;
esac
