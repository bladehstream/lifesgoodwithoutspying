#!/bin/sh
# Keep native child tools independent of Homebrew's injected preload.
unset LD_PRELOAD
# lifesgoodwithoutspying - apply privacy hardening according to the configured options.
#
# Runs at boot via run-parts and on demand from the app UI.

DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")"
. "$DIR/nospy-lib.sh"
lock_acquire || exit 1
trap lock_release EXIT

LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"

# Homebrew Channel captures nothing from init.d scripts, so log ourselves.
mkdir -p /var/lib/webosbrew 2>/dev/null || true
watch_stop || exit 1
pending_hosts_cancel

# Keep the last run separately; the UI log always starts with this apply.
if [ -f "$LOG" ]; then mv "$LOG" "$LOG.previous" || exit 1; fi

exec >>"$LOG" 2>&1
echo "Current protection run; previous run is saved separately."
echo "Build: $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$DIR/../appinfo.json")"
echo "==== apply $(date) ===="
echo applying > /var/lib/webosbrew/lifesgoodwithoutspying.result

BLOCKDIR="$DIR/blocklist.d"
DNS_FILTER_INIT="$DIR/nospy-dns-filter.sh"
DNS_FILTER_STATE="/var/lib/webosbrew/lifesgoodwithoutspying-dns-filter.state"
WORK="$(mktemp -d /tmp/lifesgoodwithoutspying.apply.XXXXXX)" || exit 1
DOMAINS_TMP="$WORK/domains"
KEYS_TMP="$WORK/keys"
UNITS_TMP="$WORK/units"
EXECS_TMP="$WORK/execs"
APPS_TMP="$WORK/apps"

# Scratch files are per-run and multi-megabyte-free, but never cleaned before;
# remove them however we exit.
trap 'lock_release; rm -f "$DOMAINS_TMP" "$KEYS_TMP" "$UNITS_TMP" "$EXECS_TMP" "$APPS_TMP" "$DNS_BLOCKLIST.tmp.$$" "$DNS_BLOCKLIST.sdp.$$"; rmdir "$WORK"' EXIT

# Remove only our mounts from /etc/hosts
# webosbrew (and potentially other apps) may have mounts on this
unmount_ours() {
    n=0
    while hosts_ours_active && [ "$n" -lt 5 ]; do
        umount /etc/hosts 2>/dev/null || umount -l /etc/hosts 2>/dev/null || break
        n=$((n + 1))
    done
}

# Emit enabled domains, once each: a host can sit in more than one category.
# During the initial sink build, domains.sdp is held back so the other
# protections can take effect immediately.
collect_domains() {
    mode="$1"
    domain_keys > "$KEYS_TMP"
    while IFS= read -r key; do
        is_on "$key" || continue
        if [ "$key" = domains.sdp ] && [ "$mode" = initial ]; then
            continue
        fi
        file="$(cat_file_for_key "$key")"
        [ -n "$file" ] || continue
        [ -f "$BLOCKDIR/$file" ] || continue
        grep -v '^[[:space:]]*#' "$BLOCKDIR/$file" | grep -v '^[[:space:]]*$'
    done < "$KEYS_TMP" | awk '!seen[$0]++'
}

mount_generated_hosts() {
    count="$1"
    if mount --bind "$HOSTS_GEN" /etc/hosts; then
        echo "[+] /etc/hosts sink applied ($count domains)"
    else
        echo "[-] failed to bind-mount /etc/hosts"
        return 1
    fi
}

# Keep valid generation artifacts even when every domain category is disabled.
# The DNS handoff can then load an intentional empty generation instead of
# retaining entries from an earlier protection generation.
write_empty_generated_hosts() {
    empty_tmp="$HOSTS_GEN.empty.$$"
    {
        echo ""
        echo "$NOSPY_MARKER generation empty-$(date +%s)-$$"
    } > "$empty_tmp" || return 1
    chmod 644 "$empty_tmp" || return 1
    mv "$empty_tmp" "$HOSTS_GEN"
}

# Publish the DNS domain artifact independently of /etc/hosts. The temporary
# file is replaced atomically so a reload can never observe a partial list.
write_dns_artifact() {
    input="$1"
    generation="$2"
    count="$(grep -c . "$input" 2>/dev/null)"
    [ -n "$count" ] || count=0
    artifact_tmp="$DNS_BLOCKLIST.tmp.$$"
    {
        echo "# lifesgoodwithoutspying dns-filter generation $generation rules $count"
        cat "$input"
    } > "$artifact_tmp" || return 1
    chmod 600 "$artifact_tmp" || return 1
    mv "$artifact_tmp" "$DNS_BLOCKLIST"
}

append_sdp_dns_artifact() {
    base_generation="$1"
    file="$(cat_file_for_key domains.sdp)"
    path="$BLOCKDIR/$file"
    [ -f "$path" ] || return 1
    grep -q "^# lifesgoodwithoutspying dns-filter generation $base_generation rules " \
        "$DNS_BLOCKLIST" 2>/dev/null || return 1

    combined="$DNS_BLOCKLIST.sdp.$$"
    sed '1d' "$DNS_BLOCKLIST" > "$combined" || return 1
    grep -v '^[[:space:]]*#' "$path" | grep -v '^[[:space:]]*$' >> "$combined" || return 1
    write_dns_artifact "$combined" "${base_generation}-sdp"
    result=$?
    rm -f "$combined"
    return "$result"
}

append_sdp_domains() {
    file="$(cat_file_for_key domains.sdp)"
    path="$BLOCKDIR/$file"
    [ -f "$path" ] || return 1
    grep -q 'nextlgsdp\.com' "$path" 2>/dev/null || return 1
    count="$(grep -v '^[[:space:]]*#' "$path" | grep -vc '^[[:space:]]*$')"
    {
        echo ""
        echo "$NOSPY_MARKER SDP clock-sync grace period complete"
        grep -v '^[[:space:]]*#' "$path" | while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            echo "0.0.0.0 $domain"
            echo ":: $domain"
        done
    } >> "$HOSTS_GEN" || return 1
    echo "$count"
}

hosts_generation_active() {
    grep -qF "$NOSPY_MARKER generation $1" /etc/hosts 2>/dev/null
}

reload_sdp_dns() {
    is_on dns.filter || return 0
    if [ ! -f "$DNS_FILTER_STATE" ]; then
        echo "[~] DNS setup is inactive; SDP rules saved for the next apply"
        return 0
    fi
    [ -x "$DNS_FILTER_INIT" ] || return 1
    "$DNS_FILTER_INIT" reload
}

# Add SDP to the already-mounted sink after LG has had time to consume
# X-Server-Time. Run asynchronously so boot hooks and UI calls return
# immediately. A generation token invalidates the worker if settings are
# re-applied or protection is disabled during the grace period.
schedule_sdp_block() {
    token="$1"
    (
        trap - EXIT HUP INT TERM
        trap '' HUP
        sleep 1
        waited=1
        while [ "$waited" -lt "$CLOCK_SYNC_DELAY" ]; do
            pending_hosts_current "$token" || exit 0
            sleep 1
            waited=$((waited + 1))
        done
        pending_hosts_current "$token" || exit 0
        unset NOSPY_LOCK_OWNER
        LOCK_HELD=0
        pending_lock_rc=0
        pending_hosts_lock "$token" || pending_lock_rc=$?
        [ "$pending_lock_rc" != 2 ] || exit 0
        if [ "$pending_lock_rc" != 0 ]; then
            # Without the lock, never mutate shared state. Leave this worker's
            # dead pending record visible; status reports the unfinished update.
            exit 1
        fi
        trap lock_release EXIT
        pending_hosts_current "$token" || exit 0
        if ! is_on domains.sdp; then
            pending_hosts_clear "$token"
            exit 0
        fi
        if ! hosts_generation_active "$token"; then
            pending_hosts_clear "$token"
            exit 0
        fi
        sdp_ok=1
        if ! hosts_ours_active; then
            sdp_ok=0
            echo "[-] our /etc/hosts sink disappeared during SDP grace period"
        elif [ "$(append_sdp_domains)" -gt 0 ] 2>/dev/null; then
            echo "[+] SDP domains blocked after ${CLOCK_SYNC_DELAY}s clock-sync grace period"
            if append_sdp_dns_artifact "$token"; then
                reload_sdp_dns || { sdp_ok=0; echo "[-] DNS filter reload failed after SDP update"; }
            else
                sdp_ok=0
                echo "[-] failed to publish DNS artifact after SDP update"
            fi
        else
            sdp_ok=0
            echo "[-] failed to add SDP domains after clock-sync grace period"
        fi
        [ "$sdp_ok" = 1 ] || echo failed > /var/lib/webosbrew/lifesgoodwithoutspying.result
        pending_hosts_clear "$token"
    ) &
    pending_pid=$!
    printf '%s %s\n' "$pending_pid" "$token" > "$HOSTS_PENDING"
    echo "[~] SDP blocked after ${CLOCK_SYNC_DELAY}s; other domain blocks are active"
}

# hosts blocking
apply_hosts() {
    if [ ! -f /etc/hosts ]; then
        echo "[-] /etc/hosts not found; refusing to touch the domain sink"
        return 1
    fi
    if [ ! -d "$BLOCKDIR" ]; then
        echo "[-] blocklist dir missing ($BLOCKDIR); skipping domain sink"
        return 1
    fi

    # Invalidate an older delayed worker, then remove only our previous mount,
    # leaving whatever is underneath.
    pending_hosts_cancel
    unmount_ours
    hosts_ours_active && { echo "[-] old hosts mount could not be removed"; return 1; }

    collect_domains initial > "$DOMAINS_TMP"
    count="$(grep -c . "$DOMAINS_TMP" 2>/dev/null)"
    [ -n "$count" ] || count=0
    sdp_pending=0
    is_on domains.sdp && sdp_pending=1
    generation="$(date +%s)-$$"

    if [ "$count" -eq 0 ] && [ "$sdp_pending" -eq 0 ]; then
        echo "[~] no domain categories enabled; our sink is off"
        write_empty_generated_hosts || return 1
        write_dns_artifact "$DOMAINS_TMP" "empty-$generation" || return 1
        rm -f "$DOMAINS_TMP" "$KEYS_TMP"
        return 0
    fi

    cp /etc/hosts "$HOSTS_GEN.tmp.$$" && mv "$HOSTS_GEN.tmp.$$" "$HOSTS_GEN" || return 1
    {
        echo ""
        echo "$NOSPY_MARKER generation $generation"
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            echo "0.0.0.0 $domain"
            echo ":: $domain"
        done < "$DOMAINS_TMP"
    } >> "$HOSTS_GEN"

    # All non-SDP blocks are active immediately. If SDP is enabled, append it
    # to this same mounted inode after the clock-sync grace period.
    if ! mount_generated_hosts "$count"; then
        rm -f "$DOMAINS_TMP" "$KEYS_TMP"
        return 1
    fi
    if ! write_dns_artifact "$DOMAINS_TMP" "$generation"; then
        echo "[-] failed to publish DNS artifact; removing incomplete hosts sink"
        unmount_ours
        rm -f "$DOMAINS_TMP" "$KEYS_TMP"
        return 1
    fi
    if [ "$sdp_pending" -eq 1 ]; then
        schedule_sdp_block "$generation"
    fi
    rm -f "$DOMAINS_TMP" "$KEYS_TMP"
}

dns_filter_ipv6_mode() {
    if is_on dns.disable_ipv6; then
        echo off
    else
        echo preserve
    fi
}

apply_dns_filter() {
    if [ -f "$DNS_FILTER_STATE" ] && [ ! -x "$DNS_FILTER_INIT" ]; then
        echo "[-] DNS handoff state exists but its rollback script is missing"
        return 1
    fi
    if is_on dns.filter; then
        if [ ! -x "$DNS_FILTER_INIT" ] || [ ! -f "$DIR/nospy-dns-filter.js" ]; then
            echo "[-] DNS filter is enabled but its helper bundle is missing"
            return 1
        fi
        # Reconfigure the complete handoff when either companion setting changes.
        # The nameserver is always part of the handoff; only IPv6 is optional.
        if [ -f "$DNS_FILTER_STATE" ]; then
            "$DNS_FILTER_INIT" disable || return 1
        fi
        NOSPY_DNS_IPV6_MODE="$(dns_filter_ipv6_mode)" "$DNS_FILTER_INIT" enable
        return $?
    fi

    if [ -f "$DNS_FILTER_STATE" ] && [ -x "$DNS_FILTER_INIT" ]; then
        "$DNS_FILTER_INIT" disable
        return $?
    fi
    if is_on dns.disable_ipv6; then
        echo "[~] dns.disable_ipv6 is companion-only; ignored while dns.filter is off"
    fi
    return 0
}

# Common apply for the stub-based categories.
#
# Turning a toggle on stops the category's units, bind-mounts an inert stub
# over each target executable, then kills whatever was already running.
# Turning it off unwinds both, so a toggle is not a one-way door.
apply_stub_category() {
    key="$1"
    unit_fn="$2"
    exec_fn="$3"

    if ! is_on "$key"; then
        stub_clear_key "$key" && units_restore "$key" || return 1
        echo "[~] $key disabled"
        return 0
    fi

    category_ok=0
    "$unit_fn" > "$UNITS_TMP"
    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        service_stop "$key" "$unit" || category_ok=1
    done < "$UNITS_TMP"

    stub_write || return 1
    stub_clear_key "$key" || return 1
    "$exec_fn" | existing_targets > "$EXECS_TMP"
    n=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -f "$path" ] || continue
        if stub_mount "$key" "$path"; then
            n=$((n + 1))
        else
            echo "[-] could not block $path"
            category_ok=1
        fi
    done < "$EXECS_TMP"
    echo "[+] $key: stubbed $n executable(s)"

    kill_by_paths "$EXECS_TMP"
    units_verify_stopped "$key" || category_ok=1
    [ "$n" -gt 0 ] || category_ok=1
    [ "$(count_running_paths "$EXECS_TMP")" = 0 ] || category_ok=1
    return "$category_ok"
}

# Ad / ACR / telemetry daemons.
apply_ads() {
    apply_stub_category ads.stop ads_units ads_execs
}

# Voice services, and the voice app if it is already up.
apply_voice() {
    apply_stub_category voice.stop voice_units voice_execs
    voice_rc=$?
    if is_on voice.stop; then
        voice_apps > "$APPS_TMP"
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            app_close "$id"
        done < "$APPS_TMP"
    fi
    return "$voice_rc"
}

# ThinQ / Alexa / IoT companions (opt-in through domains.thinq).
apply_thinq() {
    apply_stub_category domains.thinq thinq_units thinq_execs
}

# LAN discovery (ssdp/upnp)
apply_lan() {
    if ! is_on lan.block; then
        # Put the real binary back and clear any stub process that outlived its
        # mount. A stub shell still holds the "upnpd" name, so the supervisor
        # would not spawn the real binary until it is gone.
        upnp_changed=0
        upnp_unstub && upnp_changed=1
        upnp_stub_active && return 1
        # Ensure discovery is running. Both are cheap when it already is:
        # ssdp_restore is async, and upnp_restore skips the luna ping when a
        # real upnpd is up.
        ssdp_restore || return 1
        [ "$upnp_changed" = 0 ] || upnp_restore
        return 0
    fi
    if [ ! -f /usr/sbin/upnpd ]; then
        echo "[-] /usr/sbin/upnpd not found; skipping lan block"
        return 1
    fi
    if ! upnp_stub_active; then
        if mount --bind "$DIR/nospy-upnpd-stub" /usr/sbin/upnpd; then
            echo "[+] stubbed /usr/sbin/upnpd"
        else
            echo "[-] failed to stub /usr/sbin/upnpd"
            return 1
        fi
    else
        echo "[~] upnpd stub already mounted"
    fi
    # mount first, then kill: anything forked after this gets the stub.
    # Children are killed too, so a stub shell's long sleep is not orphaned.
    pids="$(pgrep upnpd 2>/dev/null | tr '\n' ' ')"
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill_with_children "$pid"
        done
        echo "[+] killed running upnpd"
    fi
    # the watcher used to keep ssdp down; do it here now.
    service_stop lan.block ssdp-discovery-lgtv.service || return 1
    if pkill -x -9 ssdp 2>/dev/null; then
        echo "[+] killed ssdp"
    fi
    units_verify_stopped lan.block
}

apply_purge() {
    if is_on purge.boot; then
        purge_residue
    fi
}

hosts_ok=1
dns_filter_ok=1
apply_hosts || hosts_ok=0
if [ "$hosts_ok" -eq 1 ]; then
    apply_dns_filter || dns_filter_ok=0
elif [ -f "$DNS_FILTER_STATE" ] && [ -x "$DNS_FILTER_INIT" ]; then
    echo "[-] domain generation failed; stopping the DNS handoff to avoid stale rules"
    "$DNS_FILTER_INIT" disable || dns_filter_ok=0
fi
apply_ok=1
apply_ads || apply_ok=0
apply_voice || apply_ok=0
apply_thinq || apply_ok=0
apply_lan || apply_ok=0
apply_purge || apply_ok=0
if [ "$apply_ok" = 1 ]; then
    watch_start || { apply_ok=0; echo "[-] could not start target maintenance"; }
fi
[ "$hosts_ok" = 1 ] && [ "$dns_filter_ok" = 1 ] && [ "$apply_ok" = 1 ] || {
    echo failed > /var/lib/webosbrew/lifesgoodwithoutspying.result
    echo "[-] selected protection checks failed; see the log"
    exit 1
}
echo passed > /var/lib/webosbrew/lifesgoodwithoutspying.result

if [ "$dns_filter_ok" -ne 1 ]; then
    echo "[-] one or more DNS handoff operations failed"
    exit 1
fi

echo "==== done ===="
