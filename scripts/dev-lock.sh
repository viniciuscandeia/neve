#!/bin/bash
# Screen lock shared by agents: dev-lock.sh acquire <owner> [timeout=600] | release <owner> | status
# Source-able: neve_lock_acquire / neve_lock_release / neve_lock_status.
NEVE_LOCK=${NEVE_LOCK:-/tmp/neve-screen.lock}

neve_lock_status() {
  [ -d "$NEVE_LOCK" ] || { echo "free"; return 1; }
  echo "held by $(cat "$NEVE_LOCK/owner" 2>/dev/null) (pid $(cat "$NEVE_LOCK/pid" 2>/dev/null))"
}
neve_lock_acquire() { # owner [timeout]; pid = caller shell ($$ / NEVE_LOCK_PID)
  local owner=$1 end=$(( $(date +%s) + ${2:-600} )) pid=${NEVE_LOCK_PID:-$PPID} p
  while ! mkdir "$NEVE_LOCK" 2>/dev/null; do
    p=$(cat "$NEVE_LOCK/pid" 2>/dev/null)
    # stale: holder dead (a lock dir without pid yet is just being created; give it a moment)
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$NEVE_LOCK"; continue; fi
    [ "$(date +%s)" -ge "$end" ] && { echo "dev-lock: timeout waiting for $(neve_lock_status)" >&2; return 1; }
    sleep 2
  done
  echo "$owner" > "$NEVE_LOCK/owner"; echo "$pid" > "$NEVE_LOCK/pid"
}
neve_lock_release() { # owner: only the owner releases
  [ "$(cat "$NEVE_LOCK/owner" 2>/dev/null)" = "$1" ] && rm -rf "$NEVE_LOCK"
  return 0
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    acquire) neve_lock_acquire "${2:?owner}" "${3:-600}" ;;
    release) neve_lock_release "${2:?owner}" ;;
    status) neve_lock_status ;;
    *) echo "usage: $0 acquire <owner> [timeout] | release <owner> | status" >&2; exit 2 ;;
  esac
fi
