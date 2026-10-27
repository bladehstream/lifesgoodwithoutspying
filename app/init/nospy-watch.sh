#!/bin/sh
# Keep native child tools independent of Homebrew's injected preload.
unset LD_PRELOAD
# Maintain selected executable mounts as LG creates/removes per-app jails.
DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")"
. "$DIR/nospy-lib.sh"
TOKEN="$1"
[ -n "$TOKEN" ] && watch_current "$TOKEN" || exit 1
unset NOSPY_LOCK_OWNER
LOCK_HELD=0
WORK="$(mktemp -d /tmp/lifesgoodwithoutspying.watch.XXXXXX)" || exit 1
SLEEP_PID=""
cleanup() {
    [ -z "$SLEEP_PID" ] || kill "$SLEEP_PID" 2>/dev/null
    lock_release
    rm -f "$WORK/targets" "$WORK/added"
    rmdir "$WORK"
    if watch_current "$TOKEN"; then rm -f "$WATCH_STATE"; fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM
while watch_current "$TOKEN"; do
    sleep 15 &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    SLEEP_PID=""
    watch_current "$TOKEN" || break
    # Never queue an old operation behind a user apply/restore.
    lock_acquire 2>/dev/null || continue
    if ! watch_current "$TOKEN"; then lock_release; break; fi
    if ! reconcile_targets "$WORK"; then
        echo "[-] target maintenance failed; reapply protection after inspecting the log"
        echo failed > "$WATCH_ERROR"
        lock_release
        exit 1
    fi
    lock_release
    LOCK_HELD=0
done
