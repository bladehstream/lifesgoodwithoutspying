#!/bin/sh
# Run only the staged DNS helper, then restore automatically. No app install,
# boot hook, service stops, hosts changes or IPv6 changes.
set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
[ "$(id -u)" = 0 ] || { echo 'Root is required'; exit 1; }
trial_init="${1:-}"
trial_seconds="${2:-60}"
case "$trial_seconds" in ''|*[!0-9]*) echo 'Invalid duration'; exit 2 ;; esac
[ "$trial_seconds" -ge 15 ] && [ "$trial_seconds" -le 120 ] || exit 2
[ -x "$trial_init/nospy-dns-filter.sh" ] && [ -f "$trial_init/nospy-dns-filter.js" ] || {
    echo 'Pass the staged init directory containing the helper and bundle'; exit 2;
}
trial_init="$(readlink -f "$trial_init")" || exit 1
mkdir -p /var/lib/webosbrew || exit 1
NOSPY_DNS_STATE_DIR="$(mktemp -d /var/lib/webosbrew/lgtvprivacy-dns-trial.XXXXXX)" || exit 1
NOSPY_DNS_BLOCKLIST=/var/lib/webosbrew/lifesgoodwithoutspying.dns
NOSPY_DNS_IPV6_MODE=preserve
NOSPY_DNS_MODE=auto
export NOSPY_DNS_STATE_DIR NOSPY_DNS_BLOCKLIST NOSPY_DNS_IPV6_MODE NOSPY_DNS_MODE
rollback() {
    trial_result=$?
    trap - EXIT HUP INT TERM
    echo 'Restoring the recorded DNS configuration...'
    if "$trial_init/nospy-dns-filter.sh" disable; then
        echo "TRIAL_RESTORED state=$NOSPY_DNS_STATE_DIR"
    else
        echo "TRIAL_RESTORE_FAILED: retain $NOSPY_DNS_STATE_DIR and inspect before proceeding"
        trial_result=1
    fi
    exit "$trial_result"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
printf 'Trial state: %s; automatic restore after %s seconds\n' "$NOSPY_DNS_STATE_DIR" "$trial_seconds"
"$trial_init/nospy-dns-filter.sh" enable || exit 1
"$trial_init/nospy-dns-filter.sh" status || exit 1
# The caller should launch this script with nohup, so closing Telnet does not
# cancel the timed restore. Leave the state/log directory available for review.
sleep "$trial_seconds"
