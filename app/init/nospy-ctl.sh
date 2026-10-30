#!/bin/sh
# lifesgoodwithoutspying control helper.
#
# Usage:
#   nospy-ctl.sh enable|disable|apply|purge|status|log
#   nospy-ctl.sh set <key> on|off   (saves only; run apply to use it)
#   nospy-ctl.sh get <key>

INITD="/var/lib/webosbrew/init.d"
LINK="$INITD/50-lifesgoodwithoutspying"
LOG="/var/lib/webosbrew/lifesgoodwithoutspying.log"
TMP="/tmp/lifesgoodwithoutspying.ctl.$$"

# Drop our scratch files however we exit.
trap 'rm -f "$TMP"*' EXIT

SELF="$(realpath "$0")"
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

# Status-only output: an early write error must not be hidden by a later
# successful printf. Keep the wrapper inside a subshell so apply is unchanged.
status_write_targets() (
    printf() { command printf "$@" || exit 1; }
    "$1"
)

# Status checks source availability, not whether rules are applied or complete.
domain_lists_status() (
    umask 077
    work="$(mktemp -d "$TMP.domain.XXXXXX")" || { echo unavailable; return; }
    keys="$work/keys"
    config="$work/config"
    trap 'rm -f "$keys" "$config"; rmdir "$work" 2>/dev/null' EXIT
    if ! status_write_targets domain_keys > "$keys" || [ ! -s "$keys" ]; then
        echo unavailable; return
    fi
    if [ -L "$CONF" ]; then
        echo unavailable; return
    elif [ -e "$CONF" ]; then
        if [ ! -f "$CONF" ] || [ ! -r "$CONF" ] || ! cat "$CONF" > "$config"; then
            echo unavailable; return
        fi
    elif ! : > "$config"; then
        echo unavailable; return
    fi
    result=none
    selected=""
    while IFS= read -r category; do
        value="$(awk -F= -v k="$category" '
            $1 == k { n++; value=substr($0, length(k)+2) }
            END { if (n > 1) exit 1; if (n == 0) print "__unset__"; else print value }
        ' "$config")" || { result=unavailable; break; }
        if [ "$value" = __unset__ ]; then
            value="$(conf_default "$category")" || { result=unavailable; break; }
        fi
        case "$value" in off) continue;; on) ;; *) result=unavailable; break;; esac
        file="$(cat_file_for_key "$category")" || { result=unavailable; break; }
        list="$DIR/blocklist.d/$file"
        if [ -z "$file" ] || [ ! -f "$list" ] || [ ! -r "$list" ] ||
            ! awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ { found=1 } END { if (!found) exit 1 }' "$list" 2>/dev/null; then
            result=unavailable; break
        fi
        selected="${selected}${selected:+,}$category"
        result=ok
    done < "$keys"
    rm -f "$keys" "$config"
    if [ "$result" = ok ]; then echo "ok:$selected"; else echo "$result"; fi
)

case "$1" in
    enable)
        mkdir -p "$INITD"
        chmod +x "$APPLY" "$REMOVE"
        "$APPLY"
        ln -sf "$APPLY" "$LINK"
        echo "autostart=on"
        ;;
    disable)
        rm -f "$LINK"
        "$REMOVE"
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
        # Only save the setting. A full apply takes 10-20 seconds, so the UI
        # collects changes and applies them once ("Update protection"); run
        # apply yourself after setting keys over SSH.
        conf_set "$key" "$val"
        echo "$key=$val"
        ;;
    get)
        conf_get "$2"
        ;;
    status)
        if [ -L "$LINK" ]; then
            echo "autostart=on"
            # Settings saved since the last apply.
            if [ ! -f "$CONF_APPLIED" ]; then
                echo "changes=pending"
            elif [ "$(conf_effective "$CONF")" = "$(conf_effective "$CONF_APPLIED")" ]; then
                echo "changes=none"
            else
                echo "changes=pending"
            fi
        else
            echo "autostart=off"
        fi
        echo "hosts=$(hosts_state)"
        echo "blocklist=$(blocklist_count)"
        echo "domain_lists=$(domain_lists_status)"
        echo "dns_filter=$(dns_filter_runtime)"
        echo "dns_filter_generation=$(dns_filter_field loaded_generation)"
        echo "dns_filter_rules=$(dns_filter_field loaded_rules)"
        echo "connman_nameservers=$(dns_filter_field connman_nameservers)"
        echo "dns_filter_ipv6_mode=$(dns_filter_field handoff_ipv6_mode)"
        echo "connman_ipv6=$(dns_filter_field connman_ipv6)"
        echo "stubs=$(stub_count)"
        conf_keys > "$TMP"
        while IFS= read -r key; do
            echo "$key=$(conf_get "$key")"
        done < "$TMP"
        rm -f "$TMP"
        if status_write_targets voice_execs > "$TMP.voice"; then
            echo "voice=$(process_inventory_state "$TMP.voice")"
        else
            echo "voice=unknown"
        fi
        if status_write_targets ads_execs > "$TMP.ads"; then
            echo "ads=$(process_inventory_state "$TMP.ads")"
        else
            echo "ads=unknown"
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
            printf "  %-30s %s\n" "$d" "$(getent hosts "$d" 2>/dev/null | awk '{print $1}' | head -1)"
        done
        printf "  %-30s %s\n" "lgtvonline.lge.com (control)" "$(getent hosts lgtvonline.lge.com 2>/dev/null | awk '{print $1}' | head -1)"
        printf "  %-30s %s\n" "gb.nextlgsdp.com (SDP clock)" "$(getent hosts gb.nextlgsdp.com 2>/dev/null | awk '{print $1}' | head -1)"
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
        if is_on clock.ntp; then
            if [ -f "$NTP_TOKEN" ]; then
                echo "  NTP clock                    pending"
            else
                echo "  NTP clock                    on (see log for the last sync)"
            fi
        fi
        echo "  Clock (UTC)                  $(date -u '+%Y-%m-%d %H:%M:%S')"
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
        voice_state=unknown
        if status_write_targets voice_execs > "$TMP.voice"; then
            voice_state="$(process_inventory_state "$TMP.voice")"
        fi
        case "$voice_state" in
            running) echo "  voice: listed process running" ;;
            stopped) echo "  voice: no listed process observed" ;;
            *) echo "  voice: process scan unavailable" ;;
        esac
        rm -f "$TMP.voice"
        echo
        echo "== ACR / ad services (effective protection check) =="
        ads_state=unknown
        if status_write_targets ads_execs > "$TMP.ads"; then
            ads_state="$(process_inventory_state "$TMP.ads")"
        fi
        case "$ads_state" in
            running) echo "  ad processes: listed process running" ;;
            stopped) echo "  ad processes: no listed process observed" ;;
            *) echo "  ad processes: process scan unavailable" ;;
        esac
        rm -f "$TMP.ads"
        echo "  Luna bus entries:"
        ls-monitor -l 2>/dev/null | grep -iE 'service\.acr|service\.livepick|colorInfoMiner|service\.admanager|service\.adoverlay|service\.tvdataexchang|acr2|nudge|rdxd|uploadd|sportsalarm' | grep -vi 'wowplay' || echo "  (none)"
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
