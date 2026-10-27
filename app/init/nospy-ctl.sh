#!/bin/sh
# Keep native child tools independent of Homebrew's injected preload.
unset LD_PRELOAD
# lifesgoodwithoutspying control helper.
#
# Usage:
#   nospy-ctl.sh enable|disable|apply|purge|status|log
#   nospy-ctl.sh set <key> on|off
#   nospy-ctl.sh get <key>

INITD="/var/lib/webosbrew/init.d"
LINK="$INITD/50-lifesgoodwithoutspying"
LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"
WORK="$(mktemp -d /tmp/lifesgoodwithoutspying.ctl.XXXXXX)" || exit 1
TMP="$WORK/ctl"

# Drop our scratch files however we exit.
trap 'lock_release; rm -f "$TMP"*; rmdir "$WORK"' EXIT

SELF="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
DIR="$(dirname "$SELF")"
. "$DIR/nospy-lib.sh"

APPLY="$DIR/nospy-apply.sh"
REMOVE="$DIR/nospy-remove.sh"

# Count each enabled domain once, as a host can sit in more than one category.
blocklist_count() {
    domain_keys > "$TMP"
    while IFS= read -r key; do
        is_on "$key" || continue
        file="$(cat_file_for_key "$key")"
        [ -n "$file" ] || continue
        [ -f "$DIR/blocklist.d/$file" ] || continue
        grep -v '^[[:space:]]*#' "$DIR/blocklist.d/$file" | grep -v '^[[:space:]]*$'
    done < "$TMP" | awk '!seen[$0]++ { n++ } END { print n + 0 }'
    rm -f "$TMP"
}

DNS_STATUS_CACHE=""
DNS_STATUS_LOADED=0

dns_filter_status() {
    if [ "$DNS_STATUS_LOADED" -eq 0 ]; then
        if [ -x "$DIR/nospy-dns-filter.sh" ]; then
            DNS_STATUS_CACHE="$("$DIR/nospy-dns-filter.sh" status 2>/dev/null)"
        fi
        DNS_STATUS_LOADED=1
    fi
    printf '%s\n' "$DNS_STATUS_CACHE"
}

dns_filter_runtime() {
    dns_filter_status | sed -n 's/^enabled=//p' | head -n 1
}

dns_filter_field() {
    dns_filter_status | sed -n "s/^$1=//p" | head -n 1
}

is_known_key() {
    conf_keys > "$TMP"
    found=1
    while IFS= read -r k; do
        if [ "$k" = "$1" ]; then
            found=0
        fi
    done < "$TMP"
    rm -f "$TMP"
    return "$found"
}

case "$1" in
    enable|disable|apply|purge|set)
        # A short maintenance pass must not make a user action fail at random.
        lock_attempt=0
        until lock_acquire 2>/dev/null; do
            [ "$lock_attempt" -lt 5 ] || { echo 'Another operation is busy; retry shortly. If interrupted, reboot before retrying.' >&2; exit 1; }
            lock_attempt=$((lock_attempt + 1))
            sleep 1
        done
        ;;
esac
case "$1" in
    enable)
        mkdir -p "$INITD"
        chmod +x "$APPLY" "$REMOVE"
        "$APPLY" || exit 1
        ln -sf "$APPLY" "$LINK" || exit 1
        echo "autostart=on"
        ;;
    disable)
        rm -f "$LINK" || exit 1
        "$REMOVE" || exit 1
        echo "autostart=off"
        ;;
    apply)
        chmod +x "$APPLY"
        "$APPLY"
        ;;
    purge)
        purge_residue
        ;;
    set)
        key="$2"
        val="$3"
        if ! is_known_key "$key"; then
            echo "unknown key: $key" >&2
            exit 2
        fi
        case "$val" in
            on|off) ;;
            *) echo "value must be on or off" >&2; exit 2 ;;
        esac
        conf_set "$key" "$val" || exit 1
        echo "$key=$val"
        # Settings while disabled must not silently activate protection.
        if [ -L "$LINK" ]; then "$APPLY"; fi
        ;;
    get)
        conf_get "$2"
        ;;
    status)
        if [ -L "$LINK" ]; then
            echo "autostart=on"
        else
            echo "autostart=off"
        fi
        echo "hosts=$(hosts_state)"
        echo "blocklist=$(blocklist_count)"
        echo "dns_filter=$(dns_filter_runtime)"
        echo "dns_filter_mode=$(dns_filter_field mode)"
        echo "dns_filter_generation=$(dns_filter_field loaded_generation)"
        echo "dns_filter_rules=$(dns_filter_field loaded_rules)"
        echo "connman_nameservers=$(dns_filter_field connman_nameservers)"
        echo "dns_filter_ipv6_mode=$(dns_filter_field handoff_ipv6_mode)"
        echo "connman_ipv6=$(dns_filter_field connman_ipv6)"
        echo "stubs=$(stub_count)"
        echo "last_apply=$(cat /var/lib/webosbrew/lifesgoodwithoutspying.result 2>/dev/null || echo unknown)"
        echo "target_maintenance=$(watch_status)"
        for category in ads.stop voice.stop domains.thinq; do
            case "$category" in ads.stop) ads_execs ;; voice.stop) voice_execs ;; *) thinq_execs ;; esac | existing_targets > "$TMP.targets"
            known=0; blocked=0
            while IFS= read -r target; do
                [ -f "$target" ] || continue
                known=$((known + 1))
                stub_owned "$target" && blocked=$((blocked + 1))
            done < "$TMP.targets"
            echo "$category.targets=$known"
            echo "$category.blocked=$blocked"
            if is_on "$category" && [ "$known" != "$blocked" ]; then
                while IFS= read -r target; do
                    stub_owned "$target" || echo "unblocked_target=$target"
                done < "$TMP.targets"
            fi
        done
        conf_keys > "$TMP"
        while IFS= read -r key; do
            echo "$key=$(conf_get "$key")"
        done < "$TMP"
        rm -f "$TMP"
        voice_execs | existing_targets > "$TMP.voice"
        ads_execs | existing_targets > "$TMP.ads"
        if [ "$(count_running_paths "$TMP.voice")" -gt 0 ]; then
            echo "voice=running"
        else
            echo "voice=stopped"
        fi
        if [ "$(count_running_paths "$TMP.ads")" -gt 0 ]; then
            echo "ads=running"
        else
            echo "ads=stopped"
        fi
        rm -f "$TMP.voice" "$TMP.ads"
        ;;
    selftest)
        echo "== generated host sink (host-side check) =="
        echo "state: $(hosts_state)   (ours = active)"
        echo "configured entries: $(blocklist_count)"
        echo "  NOTE: this confirms the mount, not how every webOS service resolves names."
        echo
        echo "== DNS filter (ConnMan handoff) =="
        if is_on dns.filter; then
            echo "configured=on"
            echo "runtime: $(dns_filter_runtime)"
            echo "coverage mode: $(dns_filter_field mode)"
            echo "ConnMan mode covers the TV resolver; direct and encrypted DNS can bypass it."
            echo "handoff IPv6 mode: $(dns_filter_field handoff_ipv6_mode)"
            echo "loaded generation: $(dns_filter_field loaded_generation)"
            echo "loaded rules: $(dns_filter_field loaded_rules)"
            if is_on dns.disable_ipv6; then
                echo "IPv6 companion: disabled while DNS filter is enabled"
            else
                echo "IPv6 companion: preserved (IPv6 DNS may bypass the helper)"
            fi
        else
            echo "configured=off"
            if is_on dns.disable_ipv6; then
                echo "IPv6 companion: configured on but inactive until dns.filter is enabled"
            else
                echo "IPv6 companion: off"
            fi
        fi
        echo
        echo "== local resolution (getent; diagnostic only) =="
        for d in ad.lgsmartad.com alphonso.tv recommend.lgtvcommon.com; do
            printf "  %-30s %s\n" "$d" "$(bounded getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)"
        done
        printf "  %-30s %s\n" "lgtvonline.lge.com (control)" "$(bounded getent hosts lgtvonline.lge.com 2>/dev/null | awk '{print $1}' | head -1)"
        printf "  %-30s %s\n" "gb.nextlgsdp.com (SDP clock)" "$(bounded getent hosts gb.nextlgsdp.com 2>/dev/null | awk '{print $1}' | head -1)"
        echo "  NOTE: getent uses this shell's resolver and the mounted /etc/hosts;"
        echo "        it does not prove that webOS daemons use the same DNS path."
        state="$(hosts_state)"
        if is_on domains.sdp; then
            case "$state" in
                waiting)
                    if [ -f "$HOSTS_GEN" ] && grep -q 'nextlgsdp\.com' "$HOSTS_GEN"; then
                        echo "  SDP clock block              FAILED (present during grace period)"
                    else
                        echo "  SDP clock block              pending (60-second grace period)"
                    fi
                    ;;
                ours)
                    if [ -f "$HOSTS_GEN" ] && grep -q 'nextlgsdp\.com' "$HOSTS_GEN"; then
                        echo "  SDP clock block              passed"
                    else
                        echo "  SDP clock block              FAILED (missing from active sink)"
                    fi
                    ;;
                open)
                    echo "  SDP clock block              not applied"
                    ;;
                *)
                    echo "  SDP clock block              unavailable ($state sink)"
                    ;;
            esac
        elif [ -f "$HOSTS_GEN" ] && grep -q 'nextlgsdp\.com' "$HOSTS_GEN"; then
            echo "  SDP clock block              FAILED (disabled but present in generated sink)"
        else
            echo "  SDP clock block              disabled"
        fi
        echo
        echo "== local outbound check (curl; diagnostic only) =="
        # -4: this build's curl stalls on dual-stack dials to the sinkhole,
        # so pin IPv4. This still uses the shell's local resolver; it is not
        # evidence that a TV service's resolver will fail.
        code="$(curl -4 -s --connect-timeout 3 -m 5 -o /dev/null -w '%{http_code}' https://ad.lgsmartad.com/ 2>/dev/null)"
        rc=$?
        echo "  ad.lgsmartad.com  http=${code:-none}  curl_rc=$rc"
        echo "  NOTE: curl also uses the mounted /etc/hosts; this is not a TV process test."
        echo
        echo "== voice processes (effective protection check) =="
        voice_execs | existing_targets > "$TMP.voice"
        if [ "$(count_running_paths "$TMP.voice")" -gt 0 ]; then
            echo "  voice: running (protection NOT active)"
        else
            echo "  voice: stopped"
        fi
        rm -f "$TMP.voice"
        echo
        echo "== ACR / ad services (effective protection check) =="
        ads_execs | existing_targets > "$TMP.ads"
        if [ "$(count_running_paths "$TMP.ads")" -gt 0 ]; then
            echo "  ad processes: running (protection NOT active)"
        else
            echo "  ad processes: stopped"
        fi
        rm -f "$TMP.ads"
        echo "  Luna bus entries:"
        bounded ls-monitor -l 2>/dev/null | grep -iE 'service\.acr|service\.livepick|colorInfoMiner|service\.admanager|service\.adoverlay|service\.tvdataexchang|acr2|nudge|rdxd|uploadd|sportsalarm' | grep -vi 'wowplay' || echo "  (none)"
        echo
        echo "== buffered ACR / voice residue files =="
        find /var/log /tmp /var/run -maxdepth 3 -type f \
            \( -iname '*acr*' -o -iname '*voice*' -o -iname '*alphonso*' -o -iname '*stt*' \) \
            2>/dev/null | wc -l
        ;;
    log)
        if [ -f "$LOG" ]; then
            tail -n 200 "$LOG"
        else
            echo "(no log yet)"
        fi
        ;;
    *)
        echo "usage: $0 enable|disable|apply|purge|status|selftest|log|set <key> on|off|get <key>" >&2
        exit 2
        ;;
esac
