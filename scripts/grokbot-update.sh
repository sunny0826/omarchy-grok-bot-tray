#!/usr/bin/env bash
# Grok Bot auto-updater for Linux (the app itself reports "此平台不支持更新").
# Fetches the official download page, compares versions, then swaps the
# FPM/deb-extracted install in ~/.local/opt with the new package.
# Fully user-level: curl + bsdtar, no sudo. Old install is kept as a
# rollback point until the new one is verified running.
set -euo pipefail

FEED_PAGE="https://cursor.com/download/bot"
# --- Network fetch policy (update path) --------------------------------
# Every request goes through fetch_bounded: https only, at most MAX_REDIRS
# redirects, a final host matching the caller's allowlist regex, and a hard
# response-size cap. Off-policy responses are refused outright - never
# truncated and used.
MAX_REDIRS=5
FEED_MAX=1048576        # feed HTML is ~135 KB; 1 MiB is ample headroom
PKG_MAX=1073741824      # the .deb is ~100 MB; 1 GiB cap
FEED_HOST_RE='^(www\.)?cursor\.com$'
PKG_HOST_RE='^downloads\.cursor\.com$'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Repository root (this script lives in scripts/): holds checksums.txt, the
# trust root for release digests — independent of the download URL.
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# App install location: GROKBOT_APP_DIR wins; default to ~/.local/opt (FPM
# extract layout), fall back to the deb's system-wide /opt path.
APP_DIR="${GROKBOT_APP_DIR:-$HOME/.local/opt/Grok Bot}"
[[ -x "$APP_DIR/grok-bot" ]] || APP_DIR="/opt/Grok Bot"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/grok-bot-tray"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/grok-bot-tray"
POLICY_FILE="$CONFIG_DIR/update-policy"
WORK="$STATE_DIR/update-work"
LOG="$STATE_DIR/update.log"
OBSERVED="$STATE_DIR/observed-digests.txt"
CTL="$SCRIPT_DIR/grokbot-ctl.sh"

# The state dir must exist before the first log line — on a fresh install
# it does not yet, and a failed log write would abort the whole updater.
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }
notify() { notify-send "Grok Bot Update" "$1" 2>/dev/null || true; }

verify_policy() {
  # strict (default) or unpinned-ok. The environment wins; otherwise read the
  # policy install.sh wrote, so the timer and the menu's "Update now" agree.
  local p="${GROKBOT_UPDATE_VERIFY:-}"
  if [[ -z "$p" && -f "$POLICY_FILE" ]]; then
    p="$(head -n 1 "$POLICY_FILE" 2>/dev/null || true)"
  fi
  if [[ "$p" == "unpinned-ok" ]]; then echo unpinned-ok; else echo strict; fi
}

# fetch_bounded <url> <out-file> <max-bytes> <max-seconds> <final-host-re>
# Bounded GET for every fetch on the update path. The body lands in
# <out-file>; unless every policy check passes the transfer is refused and
# <out-file> removed:
#   - https only and at most MAX_REDIRS redirects
#     (--proto / --proto-redir / --max-redirs), so a chain cannot wander
#     off https or loop away;
#   - the FINAL hostname after any redirect chain must match <final-host-re>
#     (checked against curl's %{url_effective}, userinfo and port stripped),
#     so a redirect can never hand the fetch to an unrelated host;
#   - the body must fit <max-bytes>: --max-filesize rejects a known-oversize
#     body before the first byte and aborts chunked ones mid-transfer on
#     curl >= 8.4.0, while `ulimit -f` (512-byte blocks) makes the kernel
#     kill any write past the cap on older curl too. An unbounded or
#     oversized response can therefore neither exhaust memory nor disk.
fetch_bounded() {
  local url="$1" out="$2" max="$3" secs="$4" host_re="$5" effective host rc
  effective="$(
    ( ulimit -f "$(( (max + 511) / 512 ))"; exec curl -fsSL --retry 2 \
        --max-time "$secs" --max-redirs "$MAX_REDIRS" \
        --proto '=https' --proto-redir '=https' --max-filesize "$max" \
        -o "$out" -w '%{url_effective}' "$url" )
  )" || rc=$?
  if [[ -n "${rc:-}" ]]; then
    log "fetch failed (curl exit $rc): $url"
    rm -f "$out"
    return 1
  fi
  host="${effective#*://}"
  host="${host%%[/?#]*}"   # drop path/query/fragment
  host="${host##*@}"       # drop any userinfo
  host="${host%%:*}"       # drop the port: TLS cert checks already pin identity
  if [[ "$effective" != https://* ]] || ! [[ "${host,,}" =~ $host_re ]]; then
    log "refused fetch: final host '${host:-?}' not allowed for $url"
    rm -f "$out"
    return 1
  fi
}

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
  local html url ver page
  page="$(mktemp "$STATE_DIR/feed.XXXXXXXXXX")" || return 1
  if ! fetch_bounded "$FEED_PAGE" "$page" "$FEED_MAX" 30 "$FEED_HOST_RE"; then
    return 1
  fi
  # fetch_bounded already capped the file at FEED_MAX; bound the read too.
  html="$(head -c "$FEED_MAX" <"$page")"
  rm -f "$page"
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

observed_digests() {
  # observed_digests <version> — unique digests recorded for that version.
  awk -v v="$1" '$1==v {print $2}' "$OBSERVED" 2>/dev/null | sort -u || true
}

forget_version() {
  # forget_version <version> — drop every recorded digest for a version.
  [[ -f "$OBSERVED" ]] || return 0
  awk -v v="$1" '$1!=v' "$OBSERVED" >"$OBSERVED.tmp"
  mv -f "$OBSERVED.tmp" "$OBSERVED"
}

record_digest() {
  # record_digest <version> <sha256> — append unless already recorded.
  grep -qxF "$1 $2" "$OBSERVED" 2>/dev/null && return 0
  echo "$1 $2" >>"$OBSERVED"
}

migrate_stale_digests() {
  # One-time cleanup for installs upgraded from the old fixed-name cache:
  # those releases reused a stale package and recorded its digest under every
  # version it was offered for. A recorded digest that equals a *pin* for a
  # different version cannot belong to the recorded version. Rewrite the file
  # once, keeping one line per version. Conflict handling afterwards is
  # strict: a recorded digest that merely matches another version's pin could
  # be a real artifact, so it is never auto-trusted.
  local marker="$STATE_DIR/observed-digests.migrated"
  [[ -f "$OBSERVED" && ! -f "$marker" ]] || return 0
  awk 'NR==FNR {if ($1 !~ /^#/) pinned_ver[$2]=$1; next}
       {if (($2 in pinned_ver) && pinned_ver[$2]!=$1) next
        if ($1 in seen) next
        seen[$1]=1; print}
      ' "$PLUGIN_ROOT/checksums.txt" "$OBSERVED" >"$OBSERVED.tmp" 2>/dev/null || return 0
  mv -f "$OBSERVED.tmp" "$OBSERVED"
  : >"$marker"
  log "migrated observed-digests.txt: dropped records that contradict a pin"
}

verify_digest() {
  # verify_digest <version> <pkg-path> — called before unpacking.
  #
  # The trust root is checksums.txt in this repository (a git-managed file,
  # independent of the mutable download URL and its same-origin companion
  # files). Policy is fail-closed by default:
  #   - pinned release: the digest MUST match, otherwise the install is
  #     refused (supply-chain protection)
  #   - unpinned release: the digest is recorded to observed-digests.txt for
  #     audit and the install is REFUSED until a maintainer reviews it and
  #     promotes it with `grokbot-update.sh pin <version>`.
  #   - GROKBOT_UPDATE_VERIFY=unpinned-ok is an explicit, documented opt-in
  #     for unattended updates. Only then is the first digest seen for a
  #     version accepted (trust-on-first-use); a later download of the same
  #     version with a different digest is still refused.
  local ver="$1" pkg="$2" sum pinned recorded
  sum="$(sha256sum "$pkg" | awk '{print $1}')"

  pinned="$(awk -v v="$ver" '$1==v {print $2}' "$PLUGIN_ROOT/checksums.txt" 2>/dev/null || true)"
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
  migrate_stale_digests
  recorded="$(observed_digests "$ver")"

  # Fail-closed default: only an independently reviewed pin may be installed.
  if [[ "$(verify_policy)" != "unpinned-ok" ]]; then
    record_digest "$ver" "$sum"
    log "refusing unpinned release $ver (fail-closed, sha256=$sum) — recorded to observed-digests.txt"
    notify "Grok Bot $ver 无 pin 校验和，已拒绝安装。审查后运行 grokbot-update.sh pin $ver；或显式设置 GROKBOT_UPDATE_VERIFY=unpinned-ok 接受首次摘要"
    return 1
  fi

  # Explicit opt-in: trust on first use, but never accept a changed digest
  # for a version that has already been seen.
  if [[ -n "$recorded" && "$recorded" != "$sum" ]]; then
    log "digest MISMATCH vs first-seen digest for unpinned $ver (expected=$recorded got=$sum)"
    notify "更新拒绝：$ver 的摘要与首次记录不符（疑似篡改）。若确认旧记录来自旧版更新器，运行 grokbot-update.sh forget $ver"
    return 1
  fi

  if [[ -z "$recorded" ]]; then
    record_digest "$ver" "$sum"
    log "unpinned release $ver accepted on first sight via unpinned-ok (sha256=$sum)"
  else
    log "unpinned release $ver matches first-seen digest (sha256=$sum)"
  fi
  return 0
}

cmd_pin() {
  # Promote a recorded digest into checksums.txt after manual review.
  local ver="${1:-}" sum
  if [[ -z "$ver" ]]; then
    echo "usage: $0 pin <version>" >&2
    exit 2
  fi
  if grep -qE "^$ver[[:space:]]" "$PLUGIN_ROOT/checksums.txt" 2>/dev/null; then
    echo "$ver is already pinned in checksums.txt"
    return 0
  fi
  sum="$(awk -v v="$ver" '$1==v {print $2}' "$OBSERVED" 2>/dev/null | tail -1)"
  if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "no observed digest for $ver in $OBSERVED" >&2
    echo "Run '$0 run' once so the digest gets recorded, review it, then retry." >&2
    exit 1
  fi
  echo "$ver $sum" >>"$PLUGIN_ROOT/checksums.txt"
  echo "pinned $ver $sum -> $PLUGIN_ROOT/checksums.txt"
  echo "Commit the file to publish the pin for other installs of this plugin."
}

cmd_forget() {
  # Drop recorded digests for a version so the next download counts as the
  # first sight again. Only needed when an old record is known to be stale.
  local ver="${1:-}"
  if [[ -z "$ver" ]]; then
    echo "usage: $0 forget <version>" >&2
    exit 2
  fi
  if [[ -z "$(observed_digests "$ver")" ]]; then
    echo "no observed digest for $ver"
    return 0
  fi
  forget_version "$ver"
  echo "forgot observed digest(s) for $ver"
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
  local lv info rv url pkg ctl_ver new_dir new_ver doc_changelog backup status i avail_kb stale
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
  # Cache keyed by version: a package fetched for one release must never be
  # verified or unpacked under another release's URL (the old fixed pkg.deb
  # name silently reused a stale 0.61.0 package for later versions).
  pkg="$WORK/grok-bot_${rv}_amd64.deb"
  for stale in "$WORK"/pkg.deb "$WORK"/grok-bot_*_amd64.deb; do
    if [[ -e "$stale" && "$stale" != "$pkg" ]]; then rm -f "$stale"; fi
  done

  # Download, reusing an already-fetched package for this exact version
  # (retry-friendly).
  if ! bsdtar -tf "$pkg" >/dev/null 2>&1; then
    rm -f "$pkg"
    fetch_bounded "$url" "$pkg" "$PKG_MAX" 900 "$PKG_HOST_RE" || { log "download failed"; notify "更新失败：下载出错（见 update.log）"; return 1; }
  fi
  bsdtar -tf "$pkg" >/dev/null 2>&1 || { log "package is not a valid deb"; notify "更新失败：包损坏（见 update.log）"; return 1; }

  # Digest gate before anything is unpacked or swapped (see verify_digest).
  verify_digest "$rv" "$pkg" || return 1

  # Clean previous unpack output, keep the downloaded package.
  rm -rf "$WORK/opt" "$WORK/usr" "$WORK/control.tar.xz" "$WORK/data.tar.xz" "$WORK/debian-binary"
  ( cd "$WORK" && bsdtar -xf "${pkg##*/}" && data="$(ls data.tar.* 2>/dev/null | head -1)" && [ -n "$data" ] && bsdtar -xf "$data" ) \
    || { log "unpack failed (deb or data layer)"; notify "更新失败：解包出错（见 update.log）"; return 1; }

  # The package's own control version is authoritative (independent of the
  # download filename): refuse a package whose contents don't match the
  # version the feed advertised.
  ctl_ver="$( (bsdtar -xOf "$pkg" 'control.tar.*' 2>/dev/null || true) | bsdtar -xOf - ./control 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -1 )"
  if [[ -n "$ctl_ver" && "$ctl_ver" != "$rv" ]]; then
    log "package control version mismatch: got '$ctl_ver', expected '$rv'"
    notify "更新失败：包版本不符（见 update.log）"
    return 1
  fi

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

  # Swap: stop cleanly, keep the old tree as rollback, move new in. The
  # backup name is reserved first with mktemp (exclusive creation of an
  # unpredictable same-directory name), so nothing that already occupies
  # any name is ever deleted or overwritten; `mv -T` then renames the old
  # tree over the reserved placeholder in one step — it can neither land
  # inside some other directory nor follow a planted link.
  "$CTL" quit || true
  backup="$(mktemp -d "$APP_DIR.bak-$lv.XXXXXXXXXX")"
  mv -T "$APP_DIR" "$backup" || {
    rmdir "$backup" 2>/dev/null || true
    log "swap: mv old install failed"
    "$CTL" start || true
    return 1
  }
  cp -f "$doc_changelog" "$new_dir/changelog.gz" 2>/dev/null || true
  mv -T "$new_dir" "$APP_DIR" || {
    log "swap: mv new install failed"
    mv -T "$backup" "$APP_DIR" || true
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
  mv -T "$backup" "$APP_DIR"
  "$CTL" start || true
  notify "更新 $rv 失败，已回滚到 $lv（见 update.log）"
  return 1
}

# Clean up records left by older updaters even when there is nothing to
# install (idempotent, one-shot via its marker file).
migrate_stale_digests

case "${1:-check}" in
  check) cmd_check ;;
  run) cmd_run ;;
  pin) shift; cmd_pin "$@" ;;
  forget) shift; cmd_forget "$@" ;;
  *) echo "usage: $0 {check|run|pin <version>|forget <version>}" >&2; exit 2 ;;
esac
