#!/bin/sh
# LG Homebrew can inject libsystrim; it breaks old BusyBox timeout children.
# This changes only this helper and its descendants, never the TV environment.
unset LD_PRELOAD
# Controlled DNS filter handoff for the webOS TV.
#
# Redirect mode filters outbound IPv4 UDP/TCP port 53 via NAT.
# ConnMan mode (for kernels without Netfilter) points the active service's DNS
# configuration at a helper restricted to local client addresses, preserving the original DNS array.
# It covers clients using ConnMan; direct/external/encrypted DNS can bypass it.
#
# The helper's own upstream queries are exempt from the redirect by source
# port: its UDP upstream socket is pinned to a fixed source port, and its TCP
# upstream connections rotate through a dedicated range.
#
# This script is intentionally separate from the normal webOS JS service. It
# is called by the opt-in init hook only after the user enables the feature.
set -u

PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
umask 077

resolve_path() { readlink -f "$1" 2>/dev/null || realpath "$1"; }
SELF="$(resolve_path "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
STATE_DIR="${NOSPY_DNS_STATE_DIR:-/var/lib/webosbrew}"
BLOCKLIST="${NOSPY_DNS_BLOCKLIST:-$STATE_DIR/lifesgoodwithoutspying.dns}"
BLOCKLIST_FORMAT="${NOSPY_DNS_BLOCKLIST_FORMAT:-domains}"
STATUS_FILE="${NOSPY_DNS_STATUS_FILE:-$STATE_DIR/lifesgoodwithoutspying-dns-filter.status}"
PID_FILE="${NOSPY_DNS_PID_FILE:-$STATE_DIR/lifesgoodwithoutspying-dns-filter.pid}"
LOG_FILE="${NOSPY_DNS_LOG_FILE:-$STATE_DIR/lifesgoodwithoutspying-dns-filter.log}"
STATE_FILE="${NOSPY_DNS_STATE_FILE:-$STATE_DIR/lifesgoodwithoutspying-dns-filter.state}"
if [ -n "${NOSPY_DNS_BUNDLE:-}" ]; then
    BUNDLE="$NOSPY_DNS_BUNDLE"
elif [ -f "$SCRIPT_DIR/nospy-dns-filter.js" ]; then
    BUNDLE="$SCRIPT_DIR/nospy-dns-filter.js"
elif [ -f "$SCRIPT_DIR/../dist/nospy-dns-filter.js" ]; then
    BUNDLE="$SCRIPT_DIR/../dist/nospy-dns-filter.js"
else
    BUNDLE="$SCRIPT_DIR/nospy-dns-filter.js"
fi
NODE="${NOSPY_DNS_NODE:-node}"
LEGACY_FIREWALL_CHAIN="${NOSPY_DNS_FIREWALL_CHAIN:-NOSPYDNS}"
IPV6_MODE="${NOSPY_DNS_IPV6_MODE:-preserve}"
TIMEOUT_SECONDS="${NOSPY_DNS_TIMEOUT_SECONDS:-8}"
SERVICE_TIMEOUT_SECONDS="${NOSPY_DNS_SERVICE_TIMEOUT_SECONDS:-30}"
HELPER_ADDRESS="${NOSPY_DNS_HELPER_ADDRESS:-127.0.0.1}"
HELPER_PORT="${NOSPY_DNS_HELPER_PORT:-5354}"
HELPER_UPSTREAM_SPORT="${NOSPY_DNS_HELPER_UPSTREAM_SPORT:-15354}"
HELPER_UPSTREAM_TCP_PORT_START="${NOSPY_DNS_HELPER_UPSTREAM_TCP_PORT_START:-15355}"
HELPER_UPSTREAM_TCP_PORT_END="${NOSPY_DNS_HELPER_UPSTREAM_TCP_PORT_END:-15483}"
RESOLV_CONF="${NOSPY_DNS_RESOLV_CONF:-/etc/resolv.conf}"
RESOLV_SOURCE="${NOSPY_DNS_RESOLV_SOURCE:-$STATE_DIR/lifesgoodwithoutspying-resolv.conf}"
RESOLV_MARKER="# lifesgoodwithoutspying dns-filter resolv.conf"

SERVICE=""
SETTINGS=""
LISTEN_ADDRESS=""
UPSTREAM=""
INTERFACE=""
ORIGINAL_NAMESERVERS=""
ORIGINAL_IPV6=""
LEGACY_FIREWALL_STARTED=0
NAT_STARTED=0
NAT_SCHEMA=2
DNS_MODE="${NOSPY_DNS_MODE:-auto}"
NAMESERVERS_CHANGED=0
KERNEL_CONFIG="${NOSPY_DNS_KERNEL_CONFIG:-/proc/config.gz}"

# BusyBox's timeout takes the duration as a bare SECS argument in 1.35 (webOS 9)
# but only as "-t SECS" in 1.29 (webOS 5/6), and each rejects the other's form
# outright. Read usage without executing a probe command; cache per process.
# Duplicated from nospy-lib.sh so this script stays standalone.
TIMEOUT_STYLE=""

log() {
    echo "dns-filter: $*"
}

detect_timeout_style() {
    [ -n "$TIMEOUT_STYLE" ] && return 0
    if ! command -v timeout >/dev/null 2>&1; then
        TIMEOUT_STYLE=none
    else
        # Never execute a syntax probe. On older LG BusyBox, invoking timeout
        # with a bare command name can recurse/hang under Homebrew exec.
        timeout_help="$(timeout --help 2>&1)"
        case "$timeout_help" in
            *'[-t SECS]'*) TIMEOUT_STYLE=flag ;;
            *' SECS PROG '*|*' DURATION COMMAND'*) TIMEOUT_STYLE=bare ;;
            *) TIMEOUT_STYLE=none ;;
        esac
    fi
    if [ "$TIMEOUT_STYLE" = none ]; then
        # stderr, because callers read this through a command substitution.
        log "no usable timeout on this build; refusing unbounded commands" >&2
    fi
    return 0
}

# Run a command with a timeout when one is usable, so one slow helper call
# cannot stall an apply or a boot hook.
bounded() {
    # This TV's BusyBox timeout cannot resolve sbin commands by bare name.
    bounded_command="$(command -v "$1")" || return 127
    shift
    detect_timeout_style
    case "$TIMEOUT_STYLE" in
        bare) timeout -s KILL 10 "$bounded_command" "$@" ;;
        flag) timeout -t 10 -s KILL "$bounded_command" "$@" ;;
        *) log "no usable timeout for $bounded_command" >&2; return 125 ;;
    esac
}

die() {
    echo "dns-filter: $*" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" = "0" ] || die "must run as root"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

read_state_value() {
    key="$1"
    [ -f "$STATE_FILE" ] || return 1
    value="$(sed -n "s/^${key}=//p" "$STATE_FILE" | tail -n 1)"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

load_state() {
    [ -f "$STATE_FILE" ] || return 1
    SERVICE="$(read_state_value SERVICE || true)"
    # The settings path is derived from SERVICE; do not trust arbitrary paths
    # from the state file.
    case "$SERVICE" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
    SETTINGS="/var/lib/connman/$SERVICE/settings"
    LISTEN_ADDRESS="$(read_state_value LISTEN_ADDRESS || true)"
    UPSTREAM="$(read_state_value UPSTREAM || true)"
    INTERFACE="$(read_state_value INTERFACE || true)"
    ORIGINAL_NAMESERVERS="$(read_state_value ORIGINAL_NAMESERVERS || true)"
    ORIGINAL_IPV6="$(read_state_value ORIGINAL_IPV6 || true)"
    # States written by 0.4.6 and earlier used the implicit strict mode.
    # Treat those as IPv6-off so an upgrade can still roll them back safely.
    IPV6_MODE="$(read_state_value IPV6_MODE || echo off)"
    case "$IPV6_MODE" in
        off|preserve) ;;
        *) IPV6_MODE=off ;;
    esac
    LEGACY_FIREWALL_STARTED="$(read_state_value FIREWALL_STARTED || echo 0)"
    NAT_STARTED="$(read_state_value NAT_STARTED || echo 0)"
    NAT_SCHEMA="$(read_state_value NAT_SCHEMA || echo 1)"
    DNS_MODE="$(read_state_value DNS_MODE || echo redirect)"
    case "$DNS_MODE" in redirect|connman) ;; *) return 1 ;; esac
    NAMESERVERS_CHANGED="$(read_state_value NAMESERVERS_CHANGED || echo 0)"
    if [ "$DNS_MODE" = connman ]; then
        HELPER_ADDRESS="$LISTEN_ADDRESS"
        HELPER_PORT=53
    fi
    [ -n "$INTERFACE" ] && [ -n "$UPSTREAM" ]
}

save_state() {
    mkdir -p "$STATE_DIR" || die "cannot create state directory: $STATE_DIR"
    {
        echo "SERVICE=$SERVICE"
        echo "LISTEN_ADDRESS=$HELPER_ADDRESS"
        echo "UPSTREAM=$UPSTREAM"
        echo "INTERFACE=$INTERFACE"
        echo "ORIGINAL_NAMESERVERS=$ORIGINAL_NAMESERVERS"
        echo "ORIGINAL_IPV6=$ORIGINAL_IPV6"
        echo "IPV6_MODE=$IPV6_MODE"
        echo "FIREWALL_STARTED=$LEGACY_FIREWALL_STARTED"
        echo "NAT_STARTED=$NAT_STARTED"
        echo "NAT_SCHEMA=$NAT_SCHEMA"
        echo "DNS_MODE=$DNS_MODE"
        echo "NAMESERVERS_CHANGED=$NAMESERVERS_CHANGED"
    } > "$STATE_FILE.tmp" || die "cannot write state: $STATE_FILE"
    mv "$STATE_FILE.tmp" "$STATE_FILE" || die "cannot commit state: $STATE_FILE"
}

clear_state() {
    rm -f "$STATE_FILE"
}

SNAPSHOT_ERROR=""
SNAPSHOT_RETRY=0

configure_connman_bus() {
    if [ -n "${DBUS_SYSTEM_BUS_ADDRESS:-}" ]; then
        return 0
    fi
    for socket_path in /tmp/var/run/dbus/system_bus_socket /var/run/dbus/system_bus_socket; do
        if [ -S "$socket_path" ]; then
            DBUS_SYSTEM_BUS_ADDRESS="unix:path=$socket_path"
            export DBUS_SYSTEM_BUS_ADDRESS
            return 0
        fi
    done
    # Let busctl try its compiled-in default if no known webOS socket exists.
    return 0
}

connman_read() {
    # Older LG connmanctl spins on EOF when stdin is not a terminal. A PTY
    # allows command-line mode to complete, including under boot/HBC/nohup.
    for connman_arg in "$@"; do
        case "$connman_arg" in ''|*[!A-Za-z0-9_.:-]*) return 2 ;; esac
    done
    cli_output="$(bounded script -q -c "connmanctl $*" /dev/null </dev/null)" || return 1
    # script emits terminal CRLF; a trailing CR otherwise turns online into
    # a different state string and makes a healthy service look offline.
    printf '%s\n' "$cli_output" | tr -d '\r'
}

active_service_ids() {
    connman_read services 2>/dev/null |
        awk '$1 ~ /[OR]/ && $NF ~ /^(wifi|ethernet)_/ { print $NF }'
}

connman_unique_name() {
    configure_connman_bus
    bounded busctl --system list 2>/dev/null |
        awk '$1 ~ /^:[0-9]/ && $0 ~ /[[:space:]]connman\.service[[:space:]]/ { print $1 }'
}

# Prefer the public well-known name; LG builds also expose a unique name.
# connmanctl is the fallback on Upstart TVs without busctl.
service_properties() {
    # Fresh status/restore processes do not inherit the bus selected by enable.
    # Set it here, before any GetProperties call, not only in a subshell used
    # to discover a unique name.
    configure_connman_bus
    if command -v busctl >/dev/null 2>&1; then
        for destination in net.connman $(connman_unique_name); do
            result="$(bounded busctl --system call "$destination" \
                "/net/connman/service/$SERVICE" net.connman.Service GetProperties 2>/dev/null)" || continue
            case "$result" in *'"State"'*) printf '%s\n' "$result"; return 0 ;; esac
        done
    fi
    result="$(connman_read services "$SERVICE" 2>/dev/null)" || return 1
    printf '%s\n' "$result" | grep -q 'State[[:space:]]*=' || return 1
    printf '%s\n' "$result"
}

# CLI dictionaries can span lines. Return one named value from a section.
cli_property() {
    awk -v section="$1" -v key="$2" '
        { text = text " " $0 }
        END {
            if (section != "") {
                pattern = section "[[:space:]]*=[[:space:]]*\\["
                if (!match(text, pattern)) exit
                text = substr(text, RSTART + RLENGTH)
                sub(/\].*$/, "", text)
            }
            pattern = "(^|[ ,])" key "[[:space:]]*=[[:space:]]*"
            if (!match(text, pattern)) exit
            text = substr(text, RSTART + RLENGTH)
            sub(/[, ].*$/, "", text)
            print text
        }'
}

bus_property() {
    section="$1"
    key="$2"
    stop_section="$3"
    awk -v section="$section" -v key="$key" -v stop_section="$stop_section" '
        function unquote(value) {
            gsub(/^"|"$/, "", value)
            return value
        }
        {
            in_section = 0
            for (i = 1; i <= NF; i++) {
                if (section == "") {
                    if ($i == "\"" key "\"") {
                        print unquote($(i + 2))
                        exit
                    }
                } else {
                    if ($i == "\"" section "\"") {
                        in_section = 1
                    } else if (in_section && stop_section != "" && $i == "\"" stop_section "\"") {
                        exit
                    }
                    if (in_section && $i == "\"" key "\"") {
                        print unquote($(i + 2))
                        exit
                    }
                }
            }
        }
    '
}

connman_property() {
    properties="$(cat)"
    case "$properties" in
        *'"State"'*) printf '%s\n' "$properties" | bus_property "$@" ;;
        *) printf '%s\n' "$properties" | cli_property "$1" "$2" ;;
    esac
}

connman_nameservers() {
    properties="$(cat)"
    case "$properties" in
      *'"State"'*) printf '%s\n' "$properties" | bus_nameservers ;;
      *) printf '%s\n' "$properties" | awk '
          { text = text " " $0 }
          END {
            if (!match(text, /(^|[ ])Nameservers[ ]*=[ ]*\[/)) exit
            text = substr(text, RSTART + RLENGTH); sub(/\].*$/, "", text)
            gsub(/[, ]+/, "\n", text); print text
          }' ;;
    esac
}

# Parse an exact typed array property. An empty array is valid; a missing
# property is an error, which must not be mistaken for automatic DNS.
bus_nameservers() {
    awk -v property="${1:-Nameservers}" '
        function unquote(value) { gsub(/^"|"$/, "", value); return value }
        {
            for (i=1; i<=NF; i++) {
                if ($i == "\"" property "\"" && $(i+1) == "as") {
                    found=1; count=$(i+2)+0
                    for (j=1; j<=count; j++) print unquote($(i+2+j))
                    exit
                }
            }
        }
        END { if (!found) exit 1 }'
}

is_ipv4_literal() {
    printf '%s\n' "$1" | awk -F. 'NF != 4 { exit 1 } { for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1 }'
}

snapshot_fail() {
    SNAPSHOT_ERROR="$1"
    SNAPSHOT_RETRY="$2"
    return 1
}

default_route_snapshot() {
    # Route lookup only; no packet is sent. Require one interface/source pair.
    bounded ip -4 route get 1.1.1.1 2>/dev/null | awk '
        { for (i=1;i<NF;i++) { if ($i=="dev") dev=$(i+1); if ($i=="src") src=$(i+1) } }
        END { if (dev!="" && src!="") print dev,src }'
}

select_routed_service() {
    selection_route="$(default_route_snapshot)"
    [ -n "$selection_route" ] || return 1
    selected_service=""; selected_count=0
    for SERVICE in $ids; do
        case "$SERVICE" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
        selection_props="$(service_properties)" || continue
        selection_state="$(printf '%s\n' "$selection_props" | connman_property '' State '')"
        case "$selection_state" in ready|online) ;; *) continue ;; esac
        selection_interface="$(printf '%s\n' "$selection_props" | connman_property Ethernet Interface IPv4)"
        selection_address="$(printf '%s\n' "$selection_props" | connman_property IPv4 Address IPv6)"
        if [ "$selection_interface $selection_address" = "$selection_route" ]; then
            selected_service="$SERVICE"
            selected_count=$((selected_count + 1))
        fi
    done
    [ "$selected_count" = 1 ] || return 1
    [ "$(default_route_snapshot)" = "$selection_route" ] || return 1
    SERVICE="$selected_service"
}

discover_service_snapshot() {
    SNAPSHOT_ERROR=""
    SNAPSHOT_RETRY=0
    configure_connman_bus
    selection_route=""
    ids="$(active_service_ids | sort -u)"
    count="$(printf '%s\n' "$ids" | awk 'NF { n++ } END { print n + 0 }')"
    if [ "$count" -gt 1 ]; then
        if ! select_routed_service; then
            snapshot_fail "multiple active ConnMan services; waiting for one stable default-route match" 1
            return 1
        fi
    fi
    if [ "$count" -eq 0 ]; then
        snapshot_fail "no active ConnMan service" 1
        return 1
    fi
    if [ "$count" = 1 ]; then SERVICE="$(printf '%s\n' "$ids" | awk 'NF { print; exit }')"; fi
    case "$SERVICE" in
        ''|*[!A-Za-z0-9_]*)
            snapshot_fail "invalid ConnMan service identifier" 0
            return 1
            ;;
    esac
    SETTINGS="/var/lib/connman/$SERVICE/settings"
    [ -f "$SETTINGS" ] || {
        snapshot_fail "ConnMan settings not found: $SETTINGS" 0
        return 1
    }

    props="$(service_properties)" || {
        snapshot_fail "could not read ConnMan properties with busctl or connmanctl" 1
        return 1
    }

    state="$(printf '%s\n' "$props" | connman_property '' State '')"
    if [ "$state" != "online" ] && [ "$state" != "ready" ]; then
        snapshot_fail "active ConnMan service is not online" 1
        return 1
    fi
    INTERFACE="$(printf '%s\n' "$props" | connman_property Ethernet Interface IPv4)"
    LISTEN_ADDRESS="$(printf '%s\n' "$props" | connman_property IPv4 Address IPv6)"
    if [ -n "$selection_route" ] &&
       { [ "$INTERFACE $LISTEN_ADDRESS" != "$selection_route" ] ||
         [ "$(default_route_snapshot)" != "$selection_route" ]; }; then
        snapshot_fail "default route changed during ConnMan snapshot" 1
        return 1
    fi
    [ -n "$INTERFACE" ] || {
        snapshot_fail "ConnMan service did not provide an Ethernet interface" 0
        return 1
    }

    nameservers="$(printf '%s\n' "$props" | connman_nameservers)"
    ipv4_nameservers=""
    ipv4_count=0
    while IFS= read -r nameserver; do
        [ -n "$nameserver" ] || continue
        if is_ipv4_literal "$nameserver"; then
            case "$nameserver" in 127.*|0.*|169.254.*|255.*) continue ;; esac
            [ -n "$ipv4_nameservers" ] || ipv4_nameservers="$nameserver"
            ipv4_count=$((ipv4_count + 1))
        fi
    done <<EOF
$nameservers
EOF
    if [ "$ipv4_count" -eq 0 ]; then
        snapshot_fail "active ConnMan service has no IPv4 nameserver" 0
        return 1
    fi
    UPSTREAM="$ipv4_nameservers"
    case "$UPSTREAM" in
        127.*|0.0.0.0)
            snapshot_fail "active ConnMan nameserver is not a safe upstream: $UPSTREAM" 0
            return 1
            ;;
    esac
    return 0
}

snapshot_clock() {
    # Boot-time clock synchronisation must not extend/shorten the retry window.
    read -r snapshot_uptime snapshot_idle < /proc/uptime || return 1
    printf '%s\n' "${snapshot_uptime%%.*}"
}

wait_for_service_snapshot() {
    case "$SERVICE_TIMEOUT_SECONDS" in ''|*[!0-9]*) return 1 ;; esac
    snapshot_start="$(snapshot_clock)" || return 1
    snapshot_deadline=$(( snapshot_start + SERVICE_TIMEOUT_SECONDS ))
    snapshot_announced=0
    while snapshot_now="$(snapshot_clock)" && [ "$snapshot_now" -lt "$snapshot_deadline" ]; do
        if discover_service_snapshot; then
            return 0
        fi
        [ "$SNAPSHOT_RETRY" = "1" ] || return 1
        if [ "$snapshot_announced" = 0 ]; then
            log "waiting for network readiness: $SNAPSHOT_ERROR"
            snapshot_announced=1
        fi
        sleep 1
    done
    return 1
}

connman_config() {
    option="$1"
    shift
    command_file="$(mktemp "$STATE_DIR/connman.XXXXXX")" || return 1
    {
        printf 'config %s %s' "$SERVICE" "$option"
        for value in "$@"; do
            printf ' %s' "$value"
        done
        printf '\nexit\n'
    } > "$command_file"
    bounded script -q -c connmanctl /dev/null < "$command_file" >/dev/null 2>&1
    result=$?
    rm -f "$command_file"
    return "$result"
}

helper_pid() {
    [ -f "$PID_FILE" ] || return 1
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    expected_node="$(command -v "$NODE")" || return 1
    [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$(resolve_path "$expected_node")" ] || return 1
    tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -qxF "$BUNDLE" || return 1
    echo "$pid"
}

helper_running() {
    helper_pid >/dev/null 2>&1
}

status_value() {
    key="$1"
    [ -f "$STATUS_FILE" ] || return 1
    value="$(sed -n "s/^${key}=//p" "$STATUS_FILE" | tail -n 1)"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

helper_socket_args() {
    if [ "$DNS_MODE" = connman ]; then
        printf '%s' --local-clients-only
    else
        printf '%s\n' "--upstream-bind-port $HELPER_UPSTREAM_SPORT --upstream-tcp-port-start $HELPER_UPSTREAM_TCP_PORT_START --upstream-tcp-port-end $HELPER_UPSTREAM_TCP_PORT_END"
    fi
}

artifact_check_output() {
    bounded "$NODE" "$BUNDLE" $(helper_socket_args) \
        --listen-address "$HELPER_ADDRESS" \
        --listen-port "$HELPER_PORT" \
        --upstream "$UPSTREAM:53" \
        --blocklist "$BLOCKLIST" \
        --blocklist-format "$BLOCKLIST_FORMAT" \
        --check 2>&1
}

# The check's own output is the only description of the failure, and the callers
# discard it. Keep the head of it: a config error also prints the usage text.
log_artifact_output() {
    if [ -z "$1" ]; then
        log "artifact check produced no output" >&2
        return 0
    fi
    printf '%s\n' "$1" | head -n 6 | while IFS= read -r line; do
        log "check: $line" >&2
    done
}

artifact_metadata() {
    output="$(artifact_check_output)"
    result=$?
    if [ "$result" -ne 0 ]; then
        log_artifact_output "$output"
        return 1
    fi
    generation="$(printf '%s\n' "$output" | sed -n 's/.*generation=\([^;]*\);.*/\1/p')"
    declared="$(printf '%s\n' "$output" | sed -n 's/.*declared_rules=\([^;]*\);.*/\1/p')"
    unique="$(printf '%s\n' "$output" | sed -n 's/^ok: \([0-9][0-9]*\) blocklist rule(s).*/\1/p')"
    if [ -z "$generation" ] || [ "$generation" = "unknown" ] ||
        [ -z "$declared" ] || [ "$declared" = "unknown" ] || [ -z "$unique" ]; then
        log_artifact_output "$output"
        return 1
    fi
    printf '%s %s %s\n' "$generation" "$declared" "$unique"
}

helper_start() {
    [ -f "$BUNDLE" ] || die "DNS bundle not found: $BUNDLE"
    [ -f "$BLOCKLIST" ] || die "generated blocklist not found: $BLOCKLIST"
    require_command "$NODE"

    metadata="$(artifact_metadata)" || die "DNS artifact check failed"
    expected_generation="$(printf '%s\n' "$metadata" | awk '{print $1}')"
    expected_declared="$(printf '%s\n' "$metadata" | awk '{print $2}')"
    expected_unique="$(printf '%s\n' "$metadata" | awk '{print $3}')"

    if helper_running; then
        die "a helper is already running; restore before starting a new handoff"
    fi

    mkdir -p "$STATE_DIR" || die "cannot create state directory: $STATE_DIR"
    rm -f "$STATUS_FILE"
    : > "$LOG_FILE"
    nohup "$NODE" "$BUNDLE" $(helper_socket_args) \
        --listen-address "$HELPER_ADDRESS" \
        --listen-port "$HELPER_PORT" \
        --upstream "$UPSTREAM:53" \
        --blocklist "$BLOCKLIST" \
        --blocklist-format "$BLOCKLIST_FORMAT" \
        --status-file "$STATUS_FILE" \
        >>"$LOG_FILE" 2>&1 </dev/null &
    pid=$!
    echo "$pid" > "$PID_FILE"

    elapsed=0
    while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            die "DNS helper exited during startup; see $LOG_FILE"
        fi
        if grep -q 'listening generation=' "$LOG_FILE" 2>/dev/null &&
            [ "$(status_value ready 2>/dev/null || true)" = "1" ] &&
            [ "$(status_value generation 2>/dev/null || true)" = "$expected_generation" ] &&
            [ "$(status_value declared_rules 2>/dev/null || true)" = "$expected_declared" ] &&
            [ "$(status_value rules 2>/dev/null || true)" = "$expected_unique" ]; then
            log "helper listening on $HELPER_ADDRESS:$HELPER_PORT (acknowledged generation $expected_generation)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    die "DNS helper did not become ready; see $LOG_FILE"
}

helper_stop() {
    pid="$(helper_pid 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        elapsed=0
        while kill -0 "$pid" 2>/dev/null && [ "$elapsed" -lt 3 ]; do
            sleep 1
            elapsed=$((elapsed + 1))
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE" "$STATUS_FILE"
}

helper_reload() {
    [ -f "$STATE_FILE" ] || die "handoff state is missing"
    load_state || die "invalid handoff state: $STATE_FILE"
    pid="$(helper_pid 2>/dev/null || true)"
    [ -n "$pid" ] || die "DNS helper is not running"
    metadata="$(artifact_metadata)" || die "DNS artifact check failed before reload"
    expected_generation="$(printf '%s\n' "$metadata" | awk '{print $1}')"
    expected_declared="$(printf '%s\n' "$metadata" | awk '{print $2}')"
    expected_unique="$(printf '%s\n' "$metadata" | awk '{print $3}')"
    old_sequence="$(status_value reload_sequence 2>/dev/null || echo 0)"

    kill -HUP "$pid" || die "could not signal DNS helper"
    elapsed=0
    while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
        sequence="$(status_value reload_sequence 2>/dev/null || echo "$old_sequence")"
        generation="$(status_value generation 2>/dev/null || true)"
        declared="$(status_value declared_rules 2>/dev/null || true)"
        unique="$(status_value rules 2>/dev/null || true)"
        reload_ok="$(status_value reload_ok 2>/dev/null || echo 0)"
        if [ "$sequence" -gt "$old_sequence" ] 2>/dev/null; then
            if [ "$reload_ok" = "1" ] &&
                [ "$generation" = "$expected_generation" ] &&
                [ "$declared" = "$expected_declared" ] &&
                [ "$unique" = "$expected_unique" ]; then
                log "reload acknowledged generation=$expected_generation rules=$expected_unique"
                return 0
            fi
            if [ "$reload_ok" = "0" ]; then
                die "DNS helper rejected the new generation"
            fi
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    die "DNS helper reload acknowledgement timed out"
}

legacy_firewall_cleanup() {
    iptables -D INPUT -i "$INTERFACE" -p tcp --dport 53 -d "$LISTEN_ADDRESS" -j "$LEGACY_FIREWALL_CHAIN" 2>/dev/null || true
    iptables -D INPUT -i "$INTERFACE" -p udp --dport 53 -d "$LISTEN_ADDRESS" -j "$LEGACY_FIREWALL_CHAIN" 2>/dev/null || true
    if iptables -n -L "$LEGACY_FIREWALL_CHAIN" >/dev/null 2>&1; then
        iptables -F "$LEGACY_FIREWALL_CHAIN" 2>/dev/null || true
        iptables -X "$LEGACY_FIREWALL_CHAIN" 2>/dev/null || true
    fi
    LEGACY_FIREWALL_STARTED=0
}

legacy_nameservers_restore() {
    # The old connMan-nameserver handoff pinned Nameservers to the TV's own
    # address. If the current settings still reflect that stale pin, restore
    # whatever was captured before the handoff ran.
    case "$LISTEN_ADDRESS" in
        ""|127.*|"$HELPER_ADDRESS")
            return 0
            ;;
    esac
    actual="$(connman_setting_value Nameservers | sed 's/;$//')"
    [ "$actual" = "$LISTEN_ADDRESS" ] || return 0
    if [ -n "$ORIGINAL_NAMESERVERS" ]; then
        old_values="$(printf '%s' "$ORIGINAL_NAMESERVERS" | sed 's/;$//' | tr ',;' '  ')"
        # Nameserver settings contain only IP literals.
        # shellcheck disable=SC2086
        connman_config --nameservers $old_values || return 1
    else
        connman_config --nameservers || return 1
    fi
    return 0
}

NAT_CHAIN=NOSPYDNS_OUT
nat_on() {
    # Never adopt a pre-existing chain whose ownership cannot be established.
    if iptables -t nat -n -L "$NAT_CHAIN" >/dev/null 2>&1; then
        die "DNS chain already exists; restore the previous installation first"
    fi
    iptables -t nat -N "$NAT_CHAIN" || die "kernel lacks the required IPv4 NAT support"
    NAT_STARTED=1
    save_state
    iptables -t nat -A "$NAT_CHAIN" -p udp --sport "$HELPER_UPSTREAM_SPORT" -j RETURN &&
    iptables -t nat -A "$NAT_CHAIN" -p tcp --sport "$HELPER_UPSTREAM_TCP_PORT_START:$HELPER_UPSTREAM_TCP_PORT_END" -j RETURN &&
    iptables -t nat -A "$NAT_CHAIN" -p udp --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" &&
    iptables -t nat -A "$NAT_CHAIN" -p tcp --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" &&
    iptables -t nat -A OUTPUT -p udp --dport 53 -j "$NAT_CHAIN" &&
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j "$NAT_CHAIN" || die "cannot install DNS redirect"
    log "IPv4 UDP/TCP DNS redirect installed"
}

nat_off() {
    if [ "$NAT_SCHEMA" = 1 ] && [ "$NAT_STARTED" = 1 ]; then
        # Only old releases recorded these exact four OUTPUT rules.
        for protocol in udp tcp; do
            if iptables -t nat -C OUTPUT -p "$protocol" --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" 2>/dev/null; then
                iptables -t nat -D OUTPUT -p "$protocol" --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" || return 1
            fi
        done
        iptables -t nat -D OUTPUT -p udp --dport 53 -m udp --sport "$HELPER_UPSTREAM_SPORT" -j ACCEPT 2>/dev/null || true
        iptables -t nat -D OUTPUT -p tcp --dport 53 -m tcp --sport "$HELPER_UPSTREAM_TCP_PORT_START:$HELPER_UPSTREAM_TCP_PORT_END" -j ACCEPT 2>/dev/null || true
        NAT_STARTED=0
        return 0
    fi
    if [ "$NAT_STARTED" = 1 ]; then
        for protocol in udp tcp; do
            if iptables -t nat -C OUTPUT -p "$protocol" --dport 53 -j "$NAT_CHAIN" 2>/dev/null; then
                iptables -t nat -D OUTPUT -p "$protocol" --dport 53 -j "$NAT_CHAIN" || return 1
            fi
        done
        if iptables -t nat -n -L "$NAT_CHAIN" >/dev/null 2>&1; then
            iptables -t nat -F "$NAT_CHAIN" && iptables -t nat -X "$NAT_CHAIN" || return 1
        fi
    fi
    NAT_STARTED=0
}

nat_active() {
    [ "$NAT_STARTED" = 1 ] &&
    iptables -t nat -C OUTPUT -p udp --dport 53 -j "$NAT_CHAIN" 2>/dev/null &&
    iptables -t nat -C OUTPUT -p tcp --dport 53 -j "$NAT_CHAIN" 2>/dev/null &&
    iptables -t nat -C "$NAT_CHAIN" -p udp --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" 2>/dev/null &&
    iptables -t nat -C "$NAT_CHAIN" -p tcp --dport 53 -j DNAT --to-destination "$HELPER_ADDRESS:$HELPER_PORT" 2>/dev/null
}

# ConnMan's resolv.conf lists ::1 before 127.0.0.1. With ConnMan IPv6 off, its
# proxy on ::1 keeps forwarding to the IPv6 upstream it learned earlier, from
# an address the interface no longer has, so those queries are never answered
# and every lookup waits out the resolver timeout before trying 127.0.0.1.
# There is no ip6tables on these kernels to divert ::1, so mount a resolv.conf
# that lists only 127.0.0.1, which the divert above sends to the helper. It is
# read-only so ConnMan cannot rewrite it in place.
resolv_target() {
    resolve_path "$RESOLV_CONF" 2>/dev/null
}

resolv_ours_active() {
    target="$(resolv_target)" || return 1
    [ "$RESOLV_SOURCE" -ef "$target" ] &&
        grep -q " $target " /proc/mounts 2>/dev/null &&
        grep -qF "$RESOLV_MARKER" "$target" 2>/dev/null
}

resolv_on() {
    resolv_off || die "previous resolver mount could not be restored"
    target="$(resolv_target)" || die "cannot resolve $RESOLV_CONF"
    {
        echo "$RESOLV_MARKER"
        echo "nameserver 127.0.0.1"
    } > "$RESOLV_SOURCE" || die "cannot write $RESOLV_SOURCE"
    chmod 644 "$RESOLV_SOURCE" || die "cannot chmod $RESOLV_SOURCE"
    mount --bind "$RESOLV_SOURCE" "$target" || die "cannot mount $RESOLV_SOURCE over $target"
    if mount -o remount,bind,ro "$target"; then
        log "resolv.conf lists only 127.0.0.1 (read-only over $target)"
    else
        log "resolv.conf lists only 127.0.0.1, but could not be made read-only; ConnMan may rewrite it"
    fi
}

resolv_off() {
    n=0
    while resolv_ours_active && [ "$n" -lt 5 ]; do
        target="$(resolv_target)"
        umount "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || break
        n=$((n + 1))
    done
    resolv_ours_active && return 1
    rm -f "$RESOLV_SOURCE"
}

capture_original_connman() {
    ORIGINAL_NAMESERVERS="$(grep '^Nameservers=' "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true)"
    ORIGINAL_IPV6="$(grep '^IPv6.method=' "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true)"
    [ -n "$ORIGINAL_IPV6" ] || ORIGINAL_IPV6=auto
}

connman_setting_value() {
    setting_key="$1"
    grep "^${setting_key}=" "$SETTINGS" 2>/dev/null |
        tail -n 1 | cut -d= -f2- || true
}

configure_connman_ipv6_on() {
    case "$IPV6_MODE" in
        off)
            connman_config --ipv6 off ||
                die "could not set ConnMan IPv6 mode"
            grep -q "^IPv6.method=off" "$SETTINGS" ||
                die "ConnMan IPv6 setting was not persisted"
            log "ConnMan IPv6 mode=off"
            ;;
        preserve)
            log "ConnMan IPv6 configuration preserved"
            ;;
        *)
            die "invalid IPv6 mode: $IPV6_MODE"
            ;;
    esac
}

verify_connman_restore() {
    if [ "$IPV6_MODE" = "off" ]; then
        actual_ipv6="$(connman_setting_value IPv6.method)"
        [ "$actual_ipv6" = "$ORIGINAL_IPV6" ] || return 1
    fi
    return 0
}

configure_connman_off() {
    restore_ok=1
    [ -n "$ORIGINAL_IPV6" ] || ORIGINAL_IPV6=auto
    if [ "$IPV6_MODE" = "off" ]; then
        connman_config --ipv6 "$ORIGINAL_IPV6" || restore_ok=0
    else
        log "ConnMan IPv6 configuration was preserved"
    fi
    if [ "$restore_ok" -ne 1 ]; then
        log "ConnMan IPv6 rollback was incomplete; retaining handoff state"
        return 1
    fi
    verify_attempt=0
    while [ "$verify_attempt" -lt 5 ]; do
        verify_connman_restore && break
        verify_attempt=$((verify_attempt + 1))
        sleep 1
    done
    if ! verify_connman_restore; then
        log "ConnMan IPv6 setting did not reach its original value; retaining handoff state"
        return 1
    fi
    log "ConnMan IPv6 configuration restored"
}

# Automatic selection never attempts to load Netfilter modules on kernels
# explicitly built without it. Unknown kernels keep the original NAT preflight.
select_dns_mode() {
    if [ "$DNS_MODE" = auto ]; then
        DNS_MODE=redirect
        if [ -r "$KERNEL_CONFIG" ] && command -v zcat >/dev/null 2>&1 &&
           zcat "$KERNEL_CONFIG" 2>/dev/null | grep -q '^# CONFIG_NETFILTER is not set$'; then
            DNS_MODE=connman
        fi
    fi
    case "$DNS_MODE" in
        redirect) ;;
        connman)
            require_command busctl
            HELPER_PORT=53
            ;;
        *) die "invalid DNS mode: $DNS_MODE" ;;
    esac
}

configure_connman_listener() {
    [ "$DNS_MODE" = connman ] || return 0
    is_ipv4_literal "$LISTEN_ADDRESS" || return 1
    case "$LISTEN_ADDRESS" in 127.*|0.*|255.*) return 1 ;; esac
    HELPER_ADDRESS="$LISTEN_ADDRESS"
    HELPER_PORT=53
}

# Never print raw GetProperties: LG includes unrelated credential fields.
# Pipeline exit status would otherwise hide a missing property.
read_nameserver_config_checked() {
    ns_props="$(service_properties)" || return 1
    ns_values="$(printf '%s\n' "$ns_props" | bus_nameservers Nameservers.Configuration)" || return 1
    printf '%s' "$ns_values" | tr '\n' ';'
}

read_effective_nameservers() {
    effective_props="$(service_properties)" || return 1
    effective_values="$(printf '%s\n' "$effective_props" | bus_nameservers)" || return 1
    printf '%s' "$effective_values" | tr '\n' ';'
}

# Use ConnMan's typed D-Bus method, including an empty array to restore DHCP DNS.
# Only IP literals from our snapshot are accepted; never source state as code.
set_nameserver_array() {
    for ns_value in "$@"; do
        case "$ns_value" in ''|*[!0-9A-Fa-f:.]*) return 1 ;; esac
    done
    configure_connman_bus
    for ns_destination in net.connman $(connman_unique_name); do
        bounded busctl --system call "$ns_destination" \
            "/net/connman/service/$SERVICE" net.connman.Service SetProperty \
            sv Nameservers.Configuration as "$#" "$@" >/dev/null 2>&1 && return 0
    done
    return 1
}

wait_nameserver_config() {
    ns_expected="$1"
    ns_attempt=0
    while [ "$ns_attempt" -lt 5 ]; do
        ns_actual="$(read_nameserver_config_checked)" || return 1
        [ "$ns_actual" = "$ns_expected" ] && return 0
        ns_attempt=$((ns_attempt+1)); sleep 1
    done
    return 1
}

connman_dns_on() {
    ns_actual="$(read_nameserver_config_checked)" || return 1
    [ "$ns_actual" = "$ORIGINAL_NAMESERVERS" ] || {
        log "DNS configuration changed since snapshot; refusing to replace it"; return 1;
    }
    NAMESERVERS_CHANGED=1
    save_state
    set_nameserver_array "$HELPER_ADDRESS" || return 1
    wait_nameserver_config "$HELPER_ADDRESS" || return 1
    [ "$(read_effective_nameservers)" = "$HELPER_ADDRESS" ] || return 1
    log "ConnMan DNS points at the TV-local helper (direct DNS can bypass it)"
}

connman_dns_off() {
    [ "$DNS_MODE" = connman ] && [ "$NAMESERVERS_CHANGED" = 1 ] || return 0
    ns_actual="$(read_nameserver_config_checked)" || return 1
    if [ "$ns_actual" != "$ORIGINAL_NAMESERVERS" ]; then
        [ "$ns_actual" = "$HELPER_ADDRESS" ] || {
            log "DNS settings changed outside this app; retaining recovery state without overwriting them"
            return 1
        }
        # Captured values are validated again by set_nameserver_array.
        ns_old_ifs="$IFS"; IFS=';'; set -- $ORIGINAL_NAMESERVERS; IFS="$ns_old_ifs"
        set_nameserver_array "$@" || return 1
        wait_nameserver_config "$ORIGINAL_NAMESERVERS" || return 1
    fi
    NAMESERVERS_CHANGED=0
    save_state
    log "original ConnMan DNS configuration restored"
}

probe_dns_path() {
    probe_generation="$(status_value generation)" || return 1
    bounded "$NODE" "$BUNDLE" --probe 127.0.0.1:53 "$probe_generation"
}

network_path_active() {
    if [ "$DNS_MODE" = connman ]; then
        [ "$NAMESERVERS_CHANGED" = 1 ] &&
        [ "$(read_nameserver_config_checked)" = "$HELPER_ADDRESS" ] &&
        [ "$(read_effective_nameservers)" = "$HELPER_ADDRESS" ]
    else
        nat_active
    fi
}

enable_failed() {
    rc=$?
    trap - EXIT
    if [ -f "$STATE_FILE" ] && load_state; then
        if connman_dns_off && resolv_off && nat_off && configure_connman_off >/dev/null 2>&1 && legacy_nameservers_restore; then
            helper_stop || true
            clear_state
        else
            log "rollback incomplete; retaining handoff state for a later retry"
        fi
    fi
    lock_release
    exit "$rc"
}

enable_handoff() {
    require_root
    case "$IPV6_MODE" in
        off|preserve) ;;
        *) die "invalid IPv6 mode: $IPV6_MODE (expected off or preserve)" ;;
    esac
    [ -f "$STATE_FILE" ] && die "handoff is already enabled; run disable first"
    NAT_SCHEMA=2
    require_command connmanctl
    require_command script
    select_dns_mode
    if [ "$IPV6_MODE" = off ]; then require_command script; fi
    require_command readlink
    if ! wait_for_service_snapshot; then
        die "could not obtain one coherent active ConnMan snapshot: $SNAPSHOT_ERROR"
    fi
    configure_connman_listener || die "no usable local IPv4 listener address"
    if [ "$DNS_MODE" = redirect ]; then
    require_command iptables
    # Ownership checks require -C; verify syntax before any network mutation.
    iptables -t nat -C OUTPUT -p udp --dport 53 -j ACCEPT >/dev/null 2>&1
    check_rc=$?
    [ "$check_rc" -le 1 ] || die "iptables rule checks (-C) are unavailable"
    iptables -t nat -S OUTPUT >/dev/null 2>&1 || die "IPv4 NAT OUTPUT is unavailable"
    fi
    capture_original_connman
    if [ "$IPV6_MODE" = off ]; then
        case "$ORIGINAL_IPV6" in auto|off) ;; *) die "IPv6 $ORIGINAL_IPV6 cannot be restored safely; use preserve mode" ;; esac
    fi
    if [ "$DNS_MODE" = connman ]; then
        ORIGINAL_NAMESERVERS="$(read_nameserver_config_checked)" || die "cannot capture typed original DNS configuration"
        for original_ns in $(printf '%s' "$ORIGINAL_NAMESERVERS" | tr ';' ' '); do
            case "$original_ns" in *[!0-9A-Fa-f:.]*) die "unsupported original DNS address" ;; esac
        done
    fi
    trap enable_failed EXIT
    save_state
    helper_start
    configure_connman_ipv6_on
    if [ "$DNS_MODE" = connman ]; then
        connman_dns_on || die "ConnMan DNS handoff did not verify"
    else
        nat_on
        if [ "$IPV6_MODE" = off ]; then resolv_on; fi
    fi
    probe_dns_path || die "DNS path did not acknowledge this helper generation; rolling back"
    save_state
    trap lock_release EXIT
    log "handoff enabled"
}

disable_handoff() {
    require_root
    if [ ! -f "$STATE_FILE" ]; then
        helper_stop
        resolv_off || return 1
        # No recorded ownership: do not touch firewall rules.
        log "handoff already disabled"
        return 0
    fi
    load_state || die "invalid handoff state: $STATE_FILE"
    connman_dns_off || { log "DNS rollback incomplete; helper and state retained"; return 1; }
    if ! legacy_nameservers_restore; then
        log "handoff remains enabled because legacy nameserver rollback failed"
        return 1
    fi
    if ! configure_connman_off; then
        log "handoff remains enabled because ConnMan rollback was incomplete"
        return 1
    fi
    resolv_off && nat_off || { log "network rollback incomplete; state retained"; return 1; }
    helper_stop
    clear_state
    log "handoff disabled"
}

status_handoff() {
    if [ -f "$STATE_FILE" ]; then
        load_state || die "invalid handoff state: $STATE_FILE"
        if helper_running && network_path_active &&
           [ "$(status_value ready 2>/dev/null || true)" = 1 ] &&
           [ "$(status_value reload_ok 2>/dev/null || true)" = 1 ] &&
           [ "$(status_value generation 2>/dev/null || true)" = "$(awk 'NR==1 {print $5}' "$BLOCKLIST" 2>/dev/null)" ] &&
           [ "$(active_service_ids)" = "$SERVICE" ] &&
           { [ "$IPV6_MODE" = preserve ] || { { [ "$DNS_MODE" = connman ] || resolv_ours_active; } && [ "$(connman_setting_value IPv6.method)" = off ]; }; } && probe_dns_path >/dev/null 2>&1; then
            echo "enabled=yes"
        else
            echo "enabled=no"
        fi
        echo "mode=$DNS_MODE"
        echo "service=$SERVICE"
        echo "listener=$HELPER_ADDRESS:$HELPER_PORT"
        echo "upstream=$UPSTREAM:53"
        echo "interface=$INTERFACE"
        echo "helper=$(helper_running && echo running || echo stopped)"
        echo "connman_nameservers=$(grep '^Nameservers=' "$SETTINGS" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
        echo "connman_ipv6=$(grep '^IPv6.method=' "$SETTINGS" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
        echo "handoff_ipv6_mode=$IPV6_MODE"
        echo "resolv_conf=$(resolv_ours_active && echo ipv4-only || echo system)"
        echo "loaded_generation=$(status_value generation 2>/dev/null || true)"
        echo "loaded_rules=$(status_value rules 2>/dev/null || true)"
        echo "loaded_declared_rules=$(status_value declared_rules 2>/dev/null || true)"
    else
        echo "enabled=no"
        echo "helper=$(helper_running && echo running || echo stopped)"
    fi
}

plan_handoff() {
    select_dns_mode
    discover_service_snapshot || die "could not obtain one coherent active ConnMan snapshot: $SNAPSHOT_ERROR"
    configure_connman_listener || die "no usable local IPv4 listener address"
    echo "mode=$DNS_MODE"
    echo "service=$SERVICE"
    echo "listener=$HELPER_ADDRESS:$HELPER_PORT"
    echo "upstream=$UPSTREAM:53"
    echo "interface=$INTERFACE"
    echo "ipv6_mode=$IPV6_MODE"
    echo "bundle=$BUNDLE"
    echo "blocklist=$BLOCKLIST"
    echo "blocklist_format=$BLOCKLIST_FORMAT"
}

LOCK_DIR=/tmp/lifesgoodwithoutspying.lock

lock_acquire() {
    if [ -n "${NOSPY_LOCK_OWNER:-}" ] &&
       [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$NOSPY_LOCK_OWNER" ]; then return 0; fi
    mkdir -p /var/lib/webosbrew || return 1
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[-] another operation owns $LOCK_DIR; if interrupted, reboot before retrying" >&2
        return 1
    fi
    NOSPY_LOCK_OWNER=$$
    export NOSPY_LOCK_OWNER
    echo "$$" > "$LOCK_DIR/pid"
    LOCK_HELD=1
}
lock_release() {
    if [ "${LOCK_HELD:-0}" = 1 ]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR"
    fi
}

case "${1:-status}" in
    enable|disable|reload) lock_acquire || exit 1; trap lock_release EXIT ;;
esac
case "${1:-status}" in
    enable) enable_handoff ;;
    disable) disable_handoff ;;
    reload) require_root; helper_reload ;;
    status) status_handoff ;;
    plan) plan_handoff ;;
    *) die "usage: $0 enable|disable|reload|status|plan" ;;
esac
