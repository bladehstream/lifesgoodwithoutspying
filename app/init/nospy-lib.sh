#!/bin/sh
# Keep native child tools independent of Homebrew's injected preload.
unset LD_PRELOAD
# lifesgoodwithoutspying shared helpers

CONF="/var/lib/webosbrew/lifesgoodwithoutspying.conf"
HOSTS_GEN="/var/lib/webosbrew/lifesgoodwithoutspying.hosts"
HOSTS_PENDING="/var/lib/webosbrew/lifesgoodwithoutspying.hosts-pending"
DNS_BLOCKLIST="/var/lib/webosbrew/lifesgoodwithoutspying.dns"
CLOCK_SYNC_DELAY=60

# Defaults
conf_default() {
    case "$1" in
        domains.acr)        echo on ;;
        domains.smartad)    echo on ;;
        domains.quickset)   echo off ;;
        domains.dashboard)  echo on ;;
        domains.wiselg)     echo off ;;
        domains.telemetry)  echo on ;;
        domains.sdp)        echo on ;;
        domains.lgchannels) echo off ;;
        domains.updates)    echo off ;;
        domains.thinq)      echo off ;;
        dns.filter)         echo off ;;
        dns.disable_ipv6)   echo off ;;
        voice.stop)         echo on ;;
        ads.stop)           echo on ;;
        lan.block)          echo off ;;
        purge.boot)         echo off ;;
        *)                  echo off ;;
    esac
}

# Print the value of a config key, or its default.
conf_get() {
    key="$1"
    if [ -f "$CONF" ]; then
        v="$(awk -F= -v k="$key" '$1 == k {print substr($0,length(k)+2)}' "$CONF" 2>/dev/null | tail -n 1)"
        if [ -n "$v" ]; then
            echo "$v"
            return 0
        fi
    fi
    conf_default "$key"
}

# Exit 0 if the key is "on".
is_on() {
    [ "$(conf_get "$1")" = "on" ]
}

# Persist a key=value pair.
conf_set() {
    key="$1"
    val="$2"
    mkdir -p "$(dirname "$CONF")"
    if [ -f "$CONF" ]; then
        awk -F= -v k="$key" '$1 != k' "$CONF" > "$CONF.tmp" 2>/dev/null || return 1
    else
        : > "$CONF.tmp" || return 1
    fi
    echo "$key=$val" >> "$CONF.tmp" || return 1
    mv "$CONF.tmp" "$CONF"
}

# Newline-separated list of every toggleable key.
conf_keys() {
    printf '%s\n' \
        domains.acr domains.smartad domains.quickset domains.dashboard \
        domains.telemetry domains.sdp domains.lgchannels domains.updates \
        domains.thinq domains.wiselg dns.filter dns.disable_ipv6 voice.stop ads.stop lan.block purge.boot
}

# Newline-separated list of domain category keys.
domain_keys() {
    printf '%s\n' \
        domains.smartad domains.quickset domains.acr domains.dashboard \
        domains.telemetry domains.sdp domains.lgchannels domains.updates \
        domains.thinq domains.wiselg
}

# Map a blocklist category key to its blocklist file name.
cat_file_for_key() {
    case "$1" in
        domains.smartad)    echo "10-smartad.txt" ;;
        domains.quickset)   echo "15-quickset.txt" ;;
        domains.acr)        echo "20-acr.txt" ;;
        domains.dashboard)  echo "30-dashboard.txt" ;;
        domains.wiselg)     echo "35-wiselg.txt" ;;
        domains.telemetry)  echo "40-telemetry.txt" ;;
        domains.sdp)        echo "45-sdp.txt" ;;
        domains.thinq)      echo "50-thinq.txt" ;;
        domains.lgchannels) echo "80-lgchannels.txt" ;;
        domains.updates)    echo "90-updates.txt" ;;
        *)                  echo "" ;;
    esac
}

# Exit 0 if our bind mount is currently over /etc/hosts.
hosts_is_mounted() {
    grep -q ' /etc/hosts ' /proc/mounts 2>/dev/null
}

# Distinctive header written into our generated hosts file, used to tell our
# mount apart from anyone else's.
NOSPY_MARKER="# lifesgoodwithoutspying - blocked LG ad/ACR/telemetry endpoints"

# A pending SDP grace-period update is identified by a token so an older
# delayed worker cannot modify a newer hosts file after a re-apply or disable.
pending_hosts_current() {
    [ -f "$HOSTS_PENDING" ] || return 1
    read -r pending_pid pending_token < "$HOSTS_PENDING"
    [ -n "$pending_pid" ] && [ "$pending_token" = "$1" ] || return 1
    kill -0 "$pending_pid" 2>/dev/null
}

pending_hosts_clear() {
    [ -f "$HOSTS_PENDING" ] || return 0
    read -r pending_pid pending_token < "$HOSTS_PENDING"
    [ "$pending_token" = "$1" ] && rm -f "$HOSTS_PENDING"
    return 0
}

pending_hosts_cancel() {
    rm -f "$HOSTS_PENDING"
}

# Return 2 when superseded/cancelled, 1 on sustained contention, 0 with lock held.
pending_hosts_lock() {
    pending_lock_token="$1"
    pending_lock_wait=0
    while pending_hosts_current "$pending_lock_token"; do
        if lock_acquire 2>/dev/null; then
            if pending_hosts_current "$pending_lock_token"; then return 0; fi
            lock_release
            return 2
        fi
        if [ "$pending_lock_wait" -ge 20 ]; then
            echo "[-] SDP update could not acquire the operation lock after 20 seconds"
            return 1
        fi
        if [ "$pending_lock_wait" = 0 ]; then
            echo "[~] SDP update waiting for the current protection operation"
        fi
        sleep 1
        pending_lock_wait=$((pending_lock_wait + 1))
    done
    return 2
}

hosts_pending() {
    [ -f "$HOSTS_PENDING" ] || return 1
    read -r pending_pid pending_token < "$HOSTS_PENDING"
    [ -n "$pending_pid" ] && [ -n "$pending_token" ] || return 1
    kill -0 "$pending_pid" 2>/dev/null
}

# Exit 0 only if OUR generated file is the mount currently on top of /etc/hosts.
hosts_ours_active() {
    hosts_is_mounted && [ /etc/hosts -ef "$HOSTS_GEN" ] &&
        grep -qF "$NOSPY_MARKER" /etc/hosts 2>/dev/null
}

# Print the state of /etc/hosts: waiting | ours | external | open.
hosts_state() {
    if hosts_pending; then
        echo "waiting"
    elif [ -f "$HOSTS_PENDING" ]; then
        echo "failed"
    elif ! hosts_is_mounted; then
        echo "open"
    elif hosts_ours_active; then
        echo "ours"
    else
        echo "external"
    fi
}

# BusyBox's timeout takes the duration as a bare SECS argument in 1.35 (webOS 9)
# but only as "-t SECS" in 1.29 (webOS 5/6), and each rejects the other's form
# outright. Read usage without executing a probe command; cache per process.
TIMEOUT_STYLE=""

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
    return 0
}

# Run a command with a timeout when one is usable to avoid a hang blocking boot
bounded() {
    # This TV's BusyBox timeout cannot resolve sbin commands by bare name.
    bounded_command="$(command -v "$1")" || return 127
    shift
    detect_timeout_style
    case "$TIMEOUT_STYLE" in
        bare) timeout -s KILL 10 "$bounded_command" "$@" ;;
        flag) timeout -t 10 -s KILL "$bounded_command" "$@" ;;
        *) echo "[-] no usable timeout; refusing an unbounded command: $bounded_command" >&2; return 125 ;;
    esac
}

# Process targets.
#
# LG starts most of these from the Luna hub (ls-hubd), so killing a process only
# gets it respawned. Instead we bind-mount an inert stub over the executable:
# the next exec exits immediately, with no polling loop needed. Matching is by
# exact /proc/<pid>/exe path, so jailed copies count too. Paths that do not
# exist on a given build are skipped at apply time.

# Candidate paths for one daemon name: the canonical directories plus any
# per-app jail copy. Jails hardlink the /usr/sbin binaries and a process may run
# from the jail path rather than the host one, so both need stubbing. Unmatched
# jail globs stay literal and are skipped by stub_mount's -f test.
target_paths() {
    printf '%s\n' "/usr/sbin/$1" "/usr/bin/$1"
    printf '%s\n' /var/palm/jail/*/usr/sbin/"$1" /var/palm/jail/*/usr/bin/"$1"
}

# Resolve symlink aliases once so mount records and /proc paths agree.
existing_targets() {
    while IFS= read -r candidate; do
        [ -f "$candidate" ] || continue
        readlink -f "$candidate" 2>/dev/null || return 1
    done | sort -u
}

# Ad / ACR / telemetry executables.
ads_execs() {
    for name in admanager livepick acr2 nudge rdxd uploadd sportsalarm \
                adoverlay-service; do
        target_paths "$name"
    done
    # app launchers that fork the daemons above
    printf '%s\n' /usr/bin/com.webos.app.livepick /usr/bin/com.webos.app.livepick-full
}

# Units the ad / telemetry daemons run under.
ads_units() {
    printf '%s\n' livepick.service nudge.service rdxd.service uploadd.service
}

# Voice / wake-word / NLP executables, plus the voice app launcher.
voice_execs() {
    for name in voiceinput voiceinput_network voiceinput_preprocessor \
                voiceinput_hidraw voiceinput_sound voiceconductor voiceclick \
                nlpmanager performer; do
        target_paths "$name"
    done
    printf '%s\n' /usr/bin/com.webos.app.voice
}

voice_units() {
    printf '%s\n' voiceinput.service voiceconductor.service
}

# Apps to ask the application manager to close. They run inside WebAppMgr, so
# exact-path matching cannot see them.
voice_apps() {
    printf '%s\n' com.webos.app.voice
}

# ThinQ / Alexa / IoT executables (acted on only when domains.thinq is on).
thinq_execs() {
    for name in trigger_thinq trigger_alexa iot-proxy iot-client mqtt-client \
                lg.thinqai.adapter amazon-alexa-adapter amazon-alexa-vsk; do
        target_paths "$name"
    done
    # iot-client also runs from its service directory
    printf '%s\n' /usr/palm/services/com.webos.service.iotclient/iot-client
}

thinq_units() {
    printf '%s\n' iot-client.service
}

# Inert stub bind-mounted over each blocked executable.
STUB_FILE="/var/lib/webosbrew/lifesgoodwithoutspying.stub"

# Records "<category> <path>" for every executable we currently have stubbed.
STUB_STATE="/var/lib/webosbrew/lifesgoodwithoutspying.stubbed"

# Write the stub body once.
stub_write() {
    mkdir -p /var/lib/webosbrew 2>/dev/null || true
    [ -f "$STUB_FILE" ] && return 0
    printf '#!/bin/sh\n# nospy executable stub v2\nexit 0\n' > "$STUB_FILE"
    chmod 755 "$STUB_FILE"
}

# Bind the stub over one executable and remember it.
stub_mount() {
    key="$1"
    path="$2"
    [ -f "$path" ] || return 1
    # Refuse unrelated mounts. Persist intent before changing the mount table.
    if awk -v p="$path" '$2 == p {found=1} END {exit !found}' /proc/mounts; then return 1; fi
    grep -qxF "$key $path" "$STUB_STATE" 2>/dev/null ||
        { echo "$key $path" >> "$STUB_STATE" || return 1; }
    mount --bind "$STUB_FILE" "$path" 2>/dev/null || return 1
    return 0
}

# Unmount everything stubbed for one category.
stub_owned() {
    # Both the mount and the distinctive bytes must match before removal.
    awk -v p="$1" '$2 == p {found=1} END {exit !found}' /proc/mounts &&
        [ "$STUB_FILE" -ef "$1" ] && cmp -s "$STUB_FILE" "$1"
}

stub_clear_key() {
    clear_key="$1"
    [ -f "$STUB_STATE" ] || return 0
    clear_ok=0
    : > "$STUB_STATE.tmp" || return 1
    while read -r category target; do
        if [ "$clear_key" != all ] && [ "$category" != "$clear_key" ]; then
            printf '%s %s\n' "$category" "$target" >> "$STUB_STATE.tmp"
            continue
        fi
        if stub_owned "$target"; then
            if ! umount "$target" 2>/dev/null; then
                printf '%s %s\n' "$category" "$target" >> "$STUB_STATE.tmp"
                clear_ok=1
            fi
        elif awk -v p="$target" '$2 == p {found=1} END {exit !found}' /proc/mounts; then
            echo "[-] foreign mount over recorded stub: $target" >&2
            printf '%s %s\n' "$category" "$target" >> "$STUB_STATE.tmp"
            clear_ok=1
        fi
    done < "$STUB_STATE"
    mv "$STUB_STATE.tmp" "$STUB_STATE" || return 1
    return "$clear_ok"
}

stub_clear_all() { stub_clear_key all; }

# How many executables we currently have stubbed.
stub_count() {
    if [ -f "$STUB_STATE" ]; then
        awk 'NF {n++} END {print n+0}' "$STUB_STATE"
    else
        echo 0
    fi
}

# Print "<pid> <exe-path>" for every process in one pass. readlink/grep per pid
# costs hundreds of forks, which is seconds slow on a TV this busy.
proc_exe_table() {
    ls -l /proc/[0-9]*/exe 2>/dev/null | awk '
        {
            target = ""
            pid_field = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "->") target = $(i + 1)
                else if ($i ~ /^\/proc\/[0-9]+\/exe$/) pid_field = $i
            }
            if (target == "" || pid_field == "") next
            sub(/^\/proc\//, "", pid_field)
            sub(/\/exe$/, "", pid_field)
            print pid_field, target
        }'
}

# Pids whose exact exe path is listed in the given file.
pids_for_paths() {
    list="$1"
    [ -f "$list" ] || return 0
    proc_exe_table | awk -v list="$list" '
        BEGIN { while ((getline line < list) > 0) want[line] = 1; close(list) }
        $2 in want { print $1 }'
}

# Kill every process whose exact exe path is listed in the given file. This
# catches the copies already running when the stub was mounted; the stub stops
# anything Luna starts afterwards.
kill_by_paths() {
    list="$1"
    [ -f "$list" ] || return 0
    pids="$(pids_for_paths "$list" | tr '\n' ' ')"
    [ -n "$pids" ] || return 0
    kill -TERM $pids 2>/dev/null
    sleep 1
    # a copy that ignored SIGTERM, or one Luna respawned in the meantime
    pids="$(pids_for_paths "$list" | tr '\n' ' ')"
    [ -n "$pids" ] || return 0
    kill -KILL $pids 2>/dev/null
    echo "[+] stopped target pid(s): $pids"
}

# Count live processes whose exact exe path is listed in the given file.
count_running_paths() {
    list="$1"
    [ -f "$list" ] || { echo 0; return 0; }
    proc_exe_table | awk -v list="$list" '
        BEGIN { while ((getline line < list) > 0) want[line] = 1; close(list) }
        $2 in want { n++ }
        END { print n + 0 }'
}

# Delete locally buffered ACR / speech-to-text files. Our own scratch files are
# excluded by name: they live in /tmp and match "voice", so without this a
# concurrent apply would delete the list a running status call is reading.
purge_residue() {
    # Firmware-specific cache paths have not been established on the target TVs.
    # Broad filename matches in /tmp and /var/run can delete unrelated state.
    echo "[-] Purge unavailable: no verified cache-path allowlist for this firmware"
    return 1
}

# Print the process id of a running app, or nothing. luna-send only emits
# output when it has a tty, so run it under script(1). Both service spellings
# exist across webOS versions, so try each.
app_pid() {
    command -v luna-send >/dev/null 2>&1 || return 0
    command -v script >/dev/null 2>&1 || return 0
    for svc in com.webos.applicationManager com.webos.service.applicationmanager; do
        running="$(bounded script -q -c \
            "luna-send -n 1 -f luna://$svc/running '{}'" \
            /dev/null 2>/dev/null)" || continue
        pid="$(printf '%s\n' "$running" | tr '{},' '\n' | awk -v id="$1" '
            index($0, "\"id\"") && index($0, id) { want = 1; next }
            want && index($0, "\"processid\"") { gsub(/[^0-9]/, ""); print; exit }')"
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
    done
}

# Ask the application manager to close an app by id. Both service spellings are
# tried; closing an app that is already down fails harmlessly.
app_close() {
    for id in "$@"; do
        [ -n "$id" ] || continue
        pid="$(app_pid "$id")"
        [ -n "$pid" ] || continue
        for svc in com.webos.applicationManager com.webos.service.applicationmanager; do
            bounded script -q -c \
                "luna-send -n 1 -f luna://$svc/close '{\"processId\":\"$pid\"}'" \
                /dev/null >/dev/null 2>&1
        done
        echo "[+] asked the application manager to close $id (pid $pid)"
    done
}

# ---------------------------------------------------------------------------
# Restore helpers.
#
# Applying stubs executables and stops services. These put everything back when
# a toggle is switched off or protection is disabled. Without them a service
# stays down until the next reboot, which is surprising from the UI.
# ---------------------------------------------------------------------------

# Start every unit we may have stopped. Safe when already running.
SERVICE_STATE=/var/lib/webosbrew/lifesgoodwithoutspying.services

service_backend() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        echo systemd
    elif command -v initctl >/dev/null 2>&1; then
        echo upstart
    fi
}

service_stop() {
    service_key="$1"; service_unit="$2"; backend="$(service_backend)"
    case "$backend" in
        systemd)
            systemctl is-active --quiet "$service_unit" || return 0
            ;;
        upstart)
            service_unit="${service_unit%.service}"
            bounded initctl status "$service_unit" 2>/dev/null | grep -q 'start/running' || return 0
            ;;
        *) return 0 ;;
    esac
    mkdir -p /var/lib/webosbrew || return 1
    record="$service_key $backend $service_unit"
    grep -qxF "$record" "$SERVICE_STATE" 2>/dev/null ||
        { echo "$record" >> "$SERVICE_STATE" || return 1; }
    case "$backend" in
        # Some LG daemons ignore TERM. Queue the stop, then let the category's
        # exact executable cleanup run before checking that the unit stopped.
        systemd) bounded systemctl --no-block stop "$service_unit" ;;
        upstart) bounded initctl stop "$service_unit" ;;
    esac
}

units_verify_stopped() {
    verify_key="$1"
    [ -f "$SERVICE_STATE" ] || return 0
    verify_rc=0
    while read -r category backend unit; do
        [ "$category" = "$verify_key" ] || continue
        attempts=0
        stopped=0
        while [ "$attempts" -lt 10 ]; do
            case "$backend" in
                systemd)
                    state="$(bounded systemctl show "$unit" -p ActiveState --value)" || state=unknown
                    case "$state" in inactive|failed) stopped=1 ;; esac
                    ;;
                upstart)
                    bounded initctl status "$unit" 2>/dev/null | grep -q 'stop/waiting' && stopped=1
                    ;;
            esac
            [ "$stopped" = 1 ] && break
            attempts=$((attempts + 1))
            sleep 1
        done
        if [ "$stopped" != 1 ]; then
            echo "[-] $unit did not stop; recovery record retained"
            verify_rc=1
        fi
    done < "$SERVICE_STATE"
    return "$verify_rc"
}

units_restore() {
    restore_key="${1:-all}"
    [ -f "$SERVICE_STATE" ] || return 0
    restore_rc=0
    : > "$SERVICE_STATE.tmp" || return 1
    while read -r category backend unit; do
        if [ "$restore_key" != all ] && [ "$category" != "$restore_key" ]; then
            echo "$category $backend $unit" >> "$SERVICE_STATE.tmp"
            continue
        fi
        restored=1
        case "$backend" in
            systemd) bounded systemctl start "$unit" || restored=0 ;;
            upstart) bounded initctl start "$unit" ||
                { bounded initctl status "$unit" | grep -q 'start/running' || restored=0; } ;;
            *) restored=0 ;;
        esac
        if [ "$restored" = 0 ]; then
            echo "$category $backend $unit" >> "$SERVICE_STATE.tmp"
            restore_rc=1
        fi
    done < "$SERVICE_STATE"
    mv "$SERVICE_STATE.tmp" "$SERVICE_STATE" || return 1
    return "$restore_rc"
}

ssdp_restore() { units_restore lan.block; }

# True if the real upnpd daemon is running (as opposed to our stub shell).
# Candidates are matched by comm, which is the basename of the executed file:
# for the stub that is the script name "upnpd", the same as the real binary.
# The exe link is what tells the two apart.
upnp_running() {
    for pid in $(pgrep upnpd 2>/dev/null); do
        case "$(readlink "/proc/$pid/exe" 2>/dev/null)" in
            */upnpd) return 0 ;;
        esac
    done
    return 1
}

# Kill a pid and its direct children. The upnpd stub is a shell script whose
# child is a very long sleep; killing only the shell would orphan the sleep.
kill_with_children() {
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill -9 "$child" 2>/dev/null
    done
    kill -9 "$1" 2>/dev/null
}

# Undo the upnpd stub: unmount it, then kill the stub shells the unmount leaves
# behind. A stub shell still holds the "upnpd" name, so the service supervising
# it would not spawn the real binary until it is gone. The exe check keeps a
# healthy real upnpd alive.
#
# Returns 0 if it unstubbed something, 1 if there was nothing to do.
upnp_stub_active() {
    head -n 2 /usr/sbin/upnpd 2>/dev/null | grep -q 'nospy-upnpd-stub'
}

upnp_unstub() {
    changed=0
    if upnp_stub_active; then
        if umount /usr/sbin/upnpd 2>/dev/null || umount -l /usr/sbin/upnpd 2>/dev/null; then
            echo "[+] restored /usr/sbin/upnpd"
            changed=1
        else
            # Still mounted: killing the stub would only make the supervisor
            # respawn it, so leave it for a later run.
            echo "[-] failed to unmount /usr/sbin/upnpd"
            return 1
        fi
    fi
    for pid in $(pgrep upnpd 2>/dev/null); do
        case "$(readlink "/proc/$pid/exe" 2>/dev/null)" in
            */upnpd) ;; # real daemon, leave it alone
            *) kill_with_children "$pid"
               echo "[+] killed lingering upnpd stub ($pid)"
               changed=1 ;;
        esac
    done
    if [ "$changed" -eq 1 ]; then
        sleep 1
        return 0
    fi
    return 1
}

# upnpd has no systemd unit of its own: it is spawned by
# com.webos.service.upnp, which luna starts on demand. Pinging that service is
# what LG's own bootmode-firstuse.service does to bring UPnP up.
upnp_restore() {
    command -v luna-send >/dev/null 2>&1 || return 0
    # Already up: skip the luna round-trip, which can block for its timeout.
    upnp_running && return 0
    if command -v script >/dev/null 2>&1; then
        bounded script -q -c \
            "luna-send -n 1 -f luna://com.webos.service.upnp/com/palm/luna/private/ping '{}'" \
            /dev/null >/dev/null 2>&1
    else
        bounded luna-send -n 1 -f \
            luna://com.webos.service.upnp/com/palm/luna/private/ping '{}' \
            >/dev/null 2>&1
    fi
    echo "[+] asked com.webos.service.upnp to start upnpd"
}

# Put back everything the toggles may have stopped: unstub the executables
# first, then let the units come back up.
services_restore() {
    stub_clear_all || return 1
    upnp_changed=0
    upnp_unstub && upnp_changed=1
    upnp_stub_active && return 1
    units_restore || return 1
    [ "$upnp_changed" = 0 ] || upnp_restore
    return 0
}

# A volatile generation prevents an old worker acting after restore/reapply.
WATCH_STATE=/tmp/lifesgoodwithoutspying.watch
WATCH_ERROR=/tmp/lifesgoodwithoutspying.watch-error
watch_current() {
    [ -f "$WATCH_STATE" ] || return 1
    read -r watch_pid watch_token < "$WATCH_STATE"
    [ "$watch_token" = "$1" ]
}
watch_pid_owned() {
    case "$1" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\000' '\n' < "/proc/$1/cmdline" | grep -qxF "$DIR/nospy-watch.sh" &&
        tr '\000' '\n' < "/proc/$1/cmdline" | grep -qxF "$2"
}
watch_stop() {
    if [ -f "$WATCH_STATE" ]; then
        read -r old_watch_pid old_watch_token < "$WATCH_STATE"
        # Invalidate before signalling. A worker acquiring the lock must recheck.
        rm -f "$WATCH_STATE" || return 1
        if watch_pid_owned "$old_watch_pid" "$old_watch_token"; then
            kill "$old_watch_pid" 2>/dev/null || true
        fi
    fi
    rm -f "$WATCH_ERROR"
}
watch_needed() {
    is_on ads.stop || is_on voice.stop || is_on domains.thinq
}
watch_start() {
    watch_stop || return 1
    watch_needed || return 0
    watch_nonce="$(mktemp -d /tmp/lifesgoodwithoutspying.token.XXXXXX)" || return 1
    new_watch_token="${watch_nonce##*/}"
    rmdir "$watch_nonce" || return 1
    printf '0 %s\n' "$new_watch_token" > "$WATCH_STATE" || return 1
    (
        trap '' HUP
        unset NOSPY_LOCK_OWNER
        exec sh "$DIR/nospy-watch.sh" "$new_watch_token"
    ) >> /var/lib/webosbrew/lifesgoodwithoutspying.log 2>&1 </dev/null &
    new_watch_pid=$!
    printf '%s %s\n' "$new_watch_pid" "$new_watch_token" > "$WATCH_STATE.tmp" &&
        mv "$WATCH_STATE.tmp" "$WATCH_STATE" || return 1
    kill -0 "$new_watch_pid" 2>/dev/null
}
watch_status() {
    if [ -f "$WATCH_ERROR" ]; then echo failed; return; fi
    if [ -f "$WATCH_STATE" ]; then
        read -r status_watch_pid status_watch_token < "$WATCH_STATE"
        if watch_pid_owned "$status_watch_pid" "$status_watch_token"; then
            echo running; return
        fi
    fi
    echo inactive
}

# Reconcile only explicitly selected, known executable paths. Never reconfigure
# DNS, stop extra services or invoke a complete apply from a background worker.
reconcile_targets() {
    reconcile_work="$1"
    reconcile_rc=0
    for reconcile_key in ads.stop voice.stop domains.thinq; do
        is_on "$reconcile_key" || continue
        case "$reconcile_key" in
            ads.stop) ads_execs ;; voice.stop) voice_execs ;; *) thinq_execs ;;
        esac | existing_targets > "$reconcile_work/targets" || return 1
        : > "$reconcile_work/added" || return 1
        while IFS= read -r reconcile_path; do
            # App jails can disappear while the list is being inspected.
            [ -f "$reconcile_path" ] || continue
            stub_owned "$reconcile_path" && continue
            if stub_mount "$reconcile_key" "$reconcile_path"; then
                printf '%s\n' "$reconcile_path" >> "$reconcile_work/added"
                echo "[+] late target blocked: $reconcile_path"
            else
                [ -f "$reconcile_path" ] || continue
                echo "[-] late target could not be blocked: $reconcile_path"
                reconcile_rc=1
            fi
        done < "$reconcile_work/targets"
        if [ -s "$reconcile_work/added" ]; then
            kill_by_paths "$reconcile_work/added"
            [ "$(count_running_paths "$reconcile_work/added")" = 0 ] || reconcile_rc=1
        fi
    done
    return "$reconcile_rc"
}

# Serialize UI, boot and direct shell mutations. Nested helpers inherit owner.
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
    if [ "${LOCK_HELD:-0}" = 1 ] &&
       [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "${NOSPY_LOCK_OWNER:-}" ]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR"
    fi
    LOCK_HELD=0
}
