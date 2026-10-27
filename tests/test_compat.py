"""Shell regressions with isolated files and mocked system commands; no TV mutation."""
import os
import gzip
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DNS = (ROOT/'dns-filter/scripts/tv-handoff.sh').read_text().split('case "${1:-status}"')[0]
LIB = (ROOT/'app/init/nospy-lib.sh').read_text()
CLI = '''/net/connman/service/ethernet_test_cable
  State = ready
  Ethernet = [ Method=auto, Interface=eth0, Address=aa:bb ]
  IPv4 = [ Method=dhcp, Address=192.168.1.20, Netmask=255.255.255.0 ]
  Nameservers = [ 192.168.1.1, 8.8.8.8 ]
'''
BUS = 'a{sv} 4 "State" s "online" "Ethernet" a{sv} 1 "Interface" s "eth0" "IPv4" a{sv} 1 "Address" s "192.168.1.20" "Nameservers" as 2 "192.168.1.1" "8.8.8.8"'

class Compat(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def runsh(self, body, dns=False, check=True):
        source = DNS if dns else LIB
        source = source.replace('/var/lib/webosbrew', str(self.base/'state')).replace('/var/lib/connman',str(self.base/'connman')).replace('/tmp/lifesgoodwithoutspying.lock',str(self.base/'lock'))
        script = self.base/'test.sh'
        script.write_text(source+'\n'+body+'\n')
        r = subprocess.run(['sh',str(script)],text=True,capture_output=True,timeout=10)
        if check:
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        return r

    def test_cli_properties(self):
        for section,key,expected in [('', 'State', 'ready'),('Ethernet','Interface','eth0'),('IPv4','Address','192.168.1.20')]:
            r=self.runsh(f"printf '%s\\n' {shlex.quote(CLI)} | connman_property '{section}' {key} ''",dns=True)
            self.assertEqual(r.stdout.strip(),expected)

    def test_cli_multiline_nameservers(self):
        data=CLI.replace('192.168.1.1, 8.8.8.8', '192.168.1.1,\n    8.8.8.8')
        r=self.runsh(f"printf '%s\\n' {shlex.quote(data)} | connman_nameservers",dns=True)
        self.assertEqual(r.stdout.split(),['192.168.1.1','8.8.8.8'])

    def test_bus_properties(self):
        r=self.runsh(f"printf '%s\\n' {shlex.quote(BUS)} | connman_property Ethernet Interface IPv4",dns=True)
        self.assertEqual(r.stdout.strip(),'eth0')

    def test_bus_nameservers(self):
        r=self.runsh(f"printf '%s\\n' {shlex.quote(BUS)} | connman_nameservers",dns=True)
        self.assertEqual(r.stdout.split(),['192.168.1.1','8.8.8.8'])

    def test_dns_accepts_ready_and_multiple_resolvers(self):
        p=self.base/'connman/ethernet_test_cable';p.mkdir(parents=True);(p/'settings').touch()
        r=self.runsh(f'''active_service_ids() {{ echo ethernet_test_cable; }}
service_properties() {{ printf '%s\\n' {shlex.quote(CLI)}; }}
discover_service_snapshot || {{ echo "$SNAPSHOT_ERROR"; exit 1; }}
echo "$UPSTREAM $INTERFACE"''',dns=True)
        self.assertEqual(r.stdout.strip(),'192.168.1.1 eth0')

    def test_dns_ambiguous_service_rejected(self):
        r=self.runsh("active_service_ids() { printf 'ethernet_one\\nwifi_two\\n'; }; default_route_snapshot() { return 1; }; discover_service_snapshot",dns=True,check=False)
        self.assertNotEqual(r.returncode,0)

    def routed_fixture(self, route='eth0 192.168.1.20', same=False):
        for service in ['ethernet_one','wifi_two']:
            p=self.base/'connman'/service;p.mkdir(parents=True);(p/'settings').touch()
        other=CLI if same else CLI.replace('eth0','wlan0').replace('192.168.1.20','192.168.2.20')
        return "active_service_ids() { printf 'ethernet_one\\nwifi_two\\n'; };\n"+"default_route_snapshot() { echo "+shlex.quote(route)+"; };\n"+"service_properties() { case \"$SERVICE\" in ethernet_one) printf '%s\\n' "+shlex.quote(CLI)+" ;; *) printf '%s\\n' "+shlex.quote(other)+" ;; esac; };\n"

    def test_multiple_services_select_unique_route_interface_and_address(self):
        r=self.runsh(self.routed_fixture()+"discover_service_snapshot; echo \"$SERVICE $INTERFACE $UPSTREAM\"",dns=True)
        self.assertEqual(r.stdout.strip(),'ethernet_one eth0 192.168.1.1')

    def test_startup_retries_transient_network_ambiguity(self):
        r=self.runsh('''
SERVICE_TIMEOUT_SECONDS=3
attempt=0
discover_service_snapshot() { attempt=$((attempt+1)); if [ "$attempt" = 1 ]; then SNAPSHOT_RETRY=1; SNAPSHOT_ERROR=ambiguous; return 1; fi; return 0; }
sleep() { :; }
wait_for_service_snapshot; echo "attempts=$attempt"
''',dns=True)
        self.assertIn('attempts=2',r.stdout)

    def test_duplicate_service_lines_are_deduplicated(self):
        p=self.base/'connman/ethernet_test_cable';p.mkdir(parents=True);(p/'settings').touch()
        r=self.runsh("active_service_ids() { printf 'ethernet_test_cable\\nethernet_test_cable\\n'; }; service_properties() { printf '%s\\n' "+shlex.quote(CLI)+"; }; default_route_snapshot() { echo SHOULD_NOT_USE_ROUTE; }; discover_service_snapshot; echo \"$SERVICE\"",dns=True)
        self.assertEqual(r.stdout.strip(),'ethernet_test_cable')

    def test_multiple_services_reject_duplicate_route_match(self):
        r=self.runsh(self.routed_fixture(same=True)+"discover_service_snapshot; rc=$?; echo \"$SNAPSHOT_RETRY\"; exit \"$rc\"",dns=True,check=False)
        self.assertNotEqual(r.returncode,0);self.assertEqual(r.stdout.strip(),'1')

    def test_multiple_services_reject_route_address_mismatch(self):
        r=self.runsh(self.routed_fixture(route='eth0 192.168.9.9')+"discover_service_snapshot",dns=True,check=False)
        self.assertNotEqual(r.returncode,0)

    def test_route_change_during_snapshot_is_rejected(self):
        body=self.routed_fixture()+'''
route_counter="$(mktemp)"; echo 0 > "$route_counter"
default_route_snapshot() { n=$(cat "$route_counter"); echo $((n+1)) > "$route_counter"; if [ "$n" = 0 ]; then echo 'eth0 192.168.1.20'; else echo 'wlan0 192.168.2.20'; fi; }
discover_service_snapshot
'''
        r=self.runsh(body,dns=True,check=False)
        self.assertNotEqual(r.returncode,0)

    def test_dns_failure_does_not_disable_executable_maintenance(self):
        source=(ROOT/'app/init/nospy-apply.sh').read_text().split('hosts_ok=1\n',1)[1]
        source=('hosts_ok=1\n'+source).replace('/var/lib/webosbrew',str(self.base/'state'))
        body='''
mkdir -p "$(dirname "$SERVICE_STATE")"
apply_hosts() { :; }; apply_dns_filter() { return 1; }
apply_ads() { :; }; apply_voice() { :; }; apply_thinq() { :; }
apply_lan() { :; }; apply_purge() { :; }
watch_start() { echo MAINTENANCE_STARTED; }
'''
        r=self.runsh(body+source,check=False)
        self.assertEqual(r.returncode,1)
        self.assertIn('MAINTENANCE_STARTED',r.stdout)

    def test_sdp_does_not_reload_when_dns_setup_failed(self):
        source=(ROOT/'app/init/nospy-apply.sh').read_text()
        fn=source[source.index('reload_sdp_dns()'):source.index('# Add SDP to the already-mounted')]
        r=self.runsh(fn+"\nis_on() { return 0; }; DNS_FILTER_STATE=/missing/state; reload_sdp_dns")
        self.assertIn('SDP rules saved for the next apply',r.stdout)

    def test_ipv4_rejects_invalid_octets(self):
        for value in ['999.1.1.1','abc.1.1.1','1.2.3','1.2.3.4.5']:
            self.assertNotEqual(self.runsh(f'is_ipv4_literal {value}',dns=True,check=False).returncode,0)

    def test_config_literal_keys(self):
        (self.base/'state').mkdir()
        (self.base/'state/lifesgoodwithoutspying.conf').write_text('dnsXfilter=on\ndns.filter=off\n')
        r=self.runsh('conf_get dns.filter; conf_set dns.filter on; cat "$CONF"')
        self.assertEqual(r.stdout.splitlines(),['off','dnsXfilter=on','dns.filter=on'])

    def test_config_empty_stub_count(self):
        r=self.runsh('mkdir -p "$(dirname "$STUB_STATE")"; : > "$STUB_STATE"; stub_count')
        self.assertEqual(r.stdout.strip(),'0')

    def test_failed_unmount_retains_recovery(self):
        r=self.runsh('''mkdir -p "$(dirname "$STUB_STATE")"
echo 'ads.stop /fake/admanager' > "$STUB_STATE"
stub_owned() { return 0; }; umount() { return 1; }
stub_clear_key ads.stop; rc=$?; cat "$STUB_STATE"; exit "$rc"''',check=False)
        self.assertEqual(r.returncode,1);self.assertIn('/fake/admanager',r.stdout)

    def test_restore_only_recorded_services(self):
        r=self.runsh('''mkdir -p "$(dirname "$SERVICE_STATE")"
printf 'ads.stop upstart livepick\\nvoice.stop upstart voiceinput\\n' > "$SERVICE_STATE"
bounded() { echo "$*"; }; units_restore ads.stop; cat "$SERVICE_STATE"''')
        self.assertEqual(r.stdout.splitlines(),['initctl start livepick','voice.stop upstart voiceinput'])

    def test_failed_service_restore_retains_state(self):
        r=self.runsh('''mkdir -p "$(dirname "$SERVICE_STATE")"
echo 'ads.stop upstart livepick' > "$SERVICE_STATE"
bounded() { return 1; }; units_restore ads.stop; rc=$?; cat "$SERVICE_STATE"; exit "$rc"''',check=False)
        self.assertEqual(r.returncode,1);self.assertIn('ads.stop upstart livepick',r.stdout)

    def test_mutation_lock(self):
        r=self.runsh('lock_acquire; unset NOSPY_LOCK_OWNER; lock_acquire',check=False)
        self.assertNotEqual(r.returncode,0)

    def test_old_lock_owner_cannot_remove_replacement_lock(self):
        r=self.runsh('lock_acquire; echo other-owner > "$LOCK_DIR/pid"; lock_release; test -f "$LOCK_DIR/pid"')
        self.assertEqual(r.returncode,0)

    def test_reconcile_only_selected_categories(self):
        r=self.runsh('''
WORK="$(mktemp -d)"
touch "$WORK/ad"
is_on() { [ "$1" = ads.stop ]; }
ads_execs() { echo "$WORK/ad"; }; voice_execs() { echo /voice/untouched; }
thinq_execs() { echo /thinq/untouched; }; existing_targets() { cat; }
stub_owned() { return 1; }; stub_mount() { echo "MOUNT $1 $2"; }
kill_by_paths() { cat "$1"; }; count_running_paths() { echo 0; }
reconcile_targets "$WORK"
rm -rf "$WORK"
''')
        self.assertIn('MOUNT ads.stop ',r.stdout)
        self.assertNotIn('/voice/untouched',r.stdout)
        self.assertNotIn('/thinq/untouched',r.stdout)

    def test_sdp_lock_retries_short_contention(self):
        r=self.runsh('''
mkdir -p "$(dirname "$HOSTS_PENDING")"; echo "$$ generation" > "$HOSTS_PENDING"
attempts=0
lock_acquire() { attempts=$((attempts+1)); [ "$attempts" -ge 3 ]; }
sleep() { :; }
pending_hosts_lock generation; echo "attempts=$attempts"
''')
        self.assertIn('attempts=3',r.stdout)

    def test_sdp_lock_waits_for_another_real_process(self):
        ready=self.base/'holder-ready'
        body='''
mkdir -p "$(dirname "$HOSTS_PENDING")"; echo "$$ generation" > "$HOSTS_PENDING"
sh -c 'mkdir "$1"; echo "$$" > "$1/pid"; touch "$2"; sleep 0.2; rm "$1/pid"; rmdir "$1"' holder "$LOCK_DIR" '''+shlex.quote(str(ready))+''' &
holder_pid=$!
while [ ! -f '''+shlex.quote(str(ready))+''' ]; do sleep 0.01; done
pending_hosts_lock generation || exit 1
test "$(cat "$LOCK_DIR/pid")" = "$$" || exit 1
lock_release
wait "$holder_pid"
'''
        r=self.runsh(body)
        self.assertIn('waiting for the current protection operation',r.stdout)

    def test_sdp_lock_cancellation_during_wait(self):
        r=self.runsh('''
mkdir -p "$(dirname "$HOSTS_PENDING")"; echo "$$ generation" > "$HOSTS_PENDING"
lock_acquire() { return 1; }; sleep() { pending_hosts_cancel; }
pending_hosts_lock generation
''',check=False)
        self.assertEqual(r.returncode,2)

    def test_sdp_lock_times_out_without_taking_foreign_lock(self):
        r=self.runsh('''
mkdir -p "$(dirname "$HOSTS_PENDING")"; echo "$$ generation" > "$HOSTS_PENDING"
lock_acquire() { return 1; }; sleep() { :; }
pending_hosts_lock generation
''',check=False)
        self.assertEqual(r.returncode,1)
        self.assertIn('after 20 seconds',r.stdout)

    def test_sdp_lock_rechecks_generation_after_acquiring(self):
        r=self.runsh('''
mkdir -p "$(dirname "$HOSTS_PENDING")"; echo "$$ generation" > "$HOSTS_PENDING"
lock_acquire() { pending_hosts_cancel; return 0; }
lock_release() { echo RELEASED; }
pending_hosts_lock generation
''',check=False)
        self.assertEqual(r.returncode,2)
        self.assertIn('RELEASED',r.stdout)

    def test_dead_sdp_worker_remains_visible_as_failed(self):
        r=self.runsh('''
mkdir -p "$(dirname "$HOSTS_PENDING")"; echo '99999999 generation' > "$HOSTS_PENDING"
hosts_state
''')
        self.assertEqual(r.stdout.strip(),'failed')

    def test_nested_lock(self):
        r=self.runsh('lock_acquire; lock_acquire; lock_release; test ! -d "$LOCK_DIR"')
        self.assertEqual(r.returncode,0)

    def test_purge_does_not_delete_matching_file(self):
        victim=self.base/'voice-recording';victim.write_text('keep')
        self.runsh('purge_residue',check=False)
        self.assertTrue(victim.exists())

    def test_nat_cleanup_failure_retains_state(self):
        r=self.runsh('''NAT_STARTED=1
iptables() { case "$*" in *'-C '*) return 0 ;; *'-D '*) return 1 ;; esac; }
nat_off; rc=$?; echo "$NAT_STARTED"; exit "$rc"''',dns=True,check=False)
        self.assertEqual(r.returncode,1);self.assertEqual(r.stdout.strip(),'1')

    def test_dns_status_requires_redirect(self):
        r=self.runsh('''mkdir -p "$STATE_DIR"; touch "$STATE_FILE"
load_state() { return 0; }; helper_running() { return 0; }; nat_active() { return 1; }
status_handoff''',dns=True)
        self.assertIn('enabled=no',r.stdout)

    def control_fixture(self):
        init=self.base/'init';init.mkdir()
        for filename in ['nospy-ctl.sh','nospy-lib.sh']:
            text=(ROOT/'app/init'/filename).read_text().replace('/var/lib/webosbrew',str(self.base/'state')).replace('/tmp/lifesgoodwithoutspying.lock',str(self.base/'lock'))
            (init/filename).write_text(text)
        for filename in ['nospy-apply.sh','nospy-remove.sh']:
            f=init/filename;f.write_text('#!/bin/sh\nexit 1\n');f.chmod(0o755)
        return init

    def test_enable_failure_does_not_install_boot_hook(self):
        init=self.control_fixture()
        r=subprocess.run(['sh',str(init/'nospy-ctl.sh'),'enable'],capture_output=True,text=True)
        self.assertEqual(r.returncode,1)
        self.assertFalse((self.base/'state/init.d/50-lifesgoodwithoutspying').exists())
        self.assertFalse((self.base/'lock').exists())

    def test_set_while_disabled_does_not_apply(self):
        init=self.control_fixture()
        r=subprocess.run(['sh',str(init/'nospy-ctl.sh'),'set','dns.filter','on'],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('dns.filter=on',(self.base/'state/lifesgoodwithoutspying.conf').read_text())

    def test_disable_propagates_restore_failure(self):
        init=self.control_fixture()
        r=subprocess.run(['sh',str(init/'nospy-ctl.sh'),'disable'],capture_output=True,text=True)
        self.assertEqual(r.returncode,1)
        self.assertNotIn('autostart=off',r.stdout)

    def test_disabled_sdp_not_collected(self):
        apply=(ROOT/'app/init/nospy-apply.sh').read_text()
        functions=apply[apply.index('unmount_ours()'):apply.index('hosts_ok=1')]
        r=self.runsh(functions+f"\nKEYS_TMP={self.base}/keys\nBLOCKDIR={ROOT}/app/init/blocklist.d\nis_on() {{ [ \"$1\" = domains.acr ]; }}\ncollect_domains initial")
        self.assertIn('alphonso.tv',r.stdout)
        self.assertNotIn('nextlgsdp.com',r.stdout)

    def test_upstart_stop_records_only_running_jobs(self):
        r=self.runsh('''service_backend() { echo upstart; }
initctl() { case "$2" in livepick) echo 'livepick start/running, process 12' ;; *) echo 'nudge stop/waiting' ;; esac; }
bounded() { "$@"; }
service_stop ads.stop livepick.service
service_stop ads.stop nudge.service
cat "$SERVICE_STATE"''')
        self.assertEqual(r.stdout.splitlines()[-1],'ads.stop upstart livepick')
        self.assertNotIn('nudge',r.stdout)

    def test_existing_dns_enable_does_not_roll_back(self):
        r=self.runsh('''mkdir -p "$STATE_DIR"; touch "$STATE_FILE"
configure_connman_off() { echo UNEXPECTED_ROLLBACK; }
helper_stop() { echo UNEXPECTED_ROLLBACK; }
enable_handoff''',dns=True,check=False)
        self.assertNotEqual(r.returncode,0)
        self.assertNotIn('UNEXPECTED_ROLLBACK',r.stdout)

    def test_systemd_stop_queues_before_verifying_completion(self):
        r=self.runsh('''service_backend() { echo systemd; }
systemctl() { case "$1" in is-active) return 0 ;; *) echo "$*" ;; esac; }
bounded() { "$@"; }
service_stop ads.stop nudge.service
cat "$SERVICE_STATE"''')
        self.assertIn('--no-block stop nudge.service',r.stdout)
        self.assertIn('ads.stop systemd nudge.service',r.stdout)

    def test_stop_verification_waits_for_inactive_unit(self):
        r=self.runsh('''mkdir -p "$(dirname "$SERVICE_STATE")"
echo 'ads.stop systemd nudge.service' > "$SERVICE_STATE"
echo 0 > "$SERVICE_STATE.count"
bounded() { n=$(cat "$SERVICE_STATE.count"); echo $((n+1)) > "$SERVICE_STATE.count"; if [ "$n" = 0 ]; then echo deactivating; else echo inactive; fi; }
sleep() { :; }
units_verify_stopped ads.stop
cat "$SERVICE_STATE.count"''')
        self.assertEqual(r.stdout.strip(),'2')

    def test_stop_verification_rejects_stuck_unit_and_retains_recovery(self):
        r=self.runsh('''mkdir -p "$(dirname "$SERVICE_STATE")"
echo 'ads.stop systemd nudge.service' > "$SERVICE_STATE"
bounded() { echo deactivating; }; sleep() { :; }
units_verify_stopped ads.stop; rc=$?
cat "$SERVICE_STATE"; exit "$rc"''',check=False)
        self.assertEqual(r.returncode,1)
        self.assertIn('recovery record retained',r.stdout)
        self.assertIn('ads.stop systemd nudge.service',r.stdout)

    def test_symlink_targets_are_resolved_and_deduplicated(self):
        binary=self.base/'binary';binary.write_text('test')
        alias=self.base/'alias';alias.symlink_to(binary)
        r=self.runsh(f"printf '%s\\n' {binary} {alias} | existing_targets")
        self.assertEqual(r.stdout.strip(),str(binary))

    def test_upnp_failed_restore_propagates(self):
        r=self.runsh('''stub_clear_all() { return 0; }
upnp_unstub() { return 1; }; upnp_stub_active() { return 0; }
services_restore''',check=False)
        self.assertEqual(r.returncode,1)

    def test_old_connmanctl_uses_services_subcommand(self):
        r=self.runsh('''busctl() { return 1; }
bounded() { "$@"; }
connmanctl() { [ "$1" = services ] && [ "$2" = ethernet_test_cable ] || return 1; echo 'State = online'; }
connman_read() { bounded connmanctl "$@"; }
SERVICE=ethernet_test_cable
service_properties''',dns=True)
        self.assertEqual(r.stdout.strip(),'State = online')

    def test_connman_read_uses_pty_and_rejects_shell_metacharacters(self):
        r=self.runsh('''
bounded() { "$@"; }
script() { [ "$1" = -q ] && [ "$2" = -c ] || return 1; printf '%s\r\n' "$3"; }
connman_read services ethernet_test_cable
if connman_read services 'bad;command'; then exit 1; fi
''',dns=True)
        self.assertEqual(r.stdout.strip(),'connmanctl services ethernet_test_cable')

    def test_timeout_detection_only_reads_help(self):
        for dns in [False,True]:
            for usage,style in [('Usage: timeout [-t SECS] [-s SIG] PROG ARGS','flag'),('Usage: timeout [-s SIG] SECS PROG ARGS','bare'),('Usage: timeout [OPTION] DURATION COMMAND [ARG]...','bare')]:
                r=self.runsh("timeout() { [ \"$1\" = --help ] && [ \"$#\" = 1 ] || { echo UNSAFE_PROBE; return 99; }; printf '%s\\n' "+shlex.quote(usage)+"; }; detect_timeout_style; echo \"$TIMEOUT_STYLE\"",dns=dns)
                self.assertEqual(r.stdout.strip(),style)

    def test_library_clears_preload_for_native_children(self):
        script=self.base/'preload.sh'
        script.write_text('LD_PRELOAD=/example/not-loaded.so\n. '+shlex.quote(str(ROOT/'app/init/nospy-lib.sh'))+'\n/bin/sh -c \'test -z "${LD_PRELOAD:-}"\'\n')
        r=subprocess.run(['sh',str(script)],capture_output=True,text=True,timeout=5)
        self.assertEqual(r.returncode,0,r.stderr)

    def test_timeout_receives_resolved_executable(self):
        r=self.runsh('''TIMEOUT_STYLE=flag
timeout() { printf '%s\\n' "$@"; }
bounded sh -c :''')
        self.assertEqual(r.stdout.splitlines()[:5],['-t','10','-s','KILL','/usr/bin/sh'])

    def test_kernel_without_netfilter_selects_connman(self):
        config=self.base/'config.gz';config.write_bytes(gzip.compress(b'# CONFIG_NETFILTER is not set\n'))
        r=self.runsh(f'KERNEL_CONFIG={config}; select_dns_mode; LISTEN_ADDRESS=192.0.2.20; configure_connman_listener; echo "$DNS_MODE $HELPER_ADDRESS:$HELPER_PORT"',dns=True)
        self.assertEqual(r.stdout.strip(),'connman 192.0.2.20:53')

    def test_kernel_with_netfilter_keeps_redirect(self):
        config=self.base/'config.gz';config.write_bytes(gzip.compress(b'CONFIG_NETFILTER=y\n'))
        r=self.runsh(f'KERNEL_CONFIG={config}; select_dns_mode; echo "$DNS_MODE"',dns=True)
        self.assertEqual(r.stdout.strip(),'redirect')

    def test_missing_typed_dns_property_is_not_automatic(self):
        r=self.runsh('''service_properties() { echo 'a{sv} 1 "State" s "online"'; }
read_nameserver_config_checked''',dns=True,check=False)
        self.assertEqual(r.returncode,1)

    def test_empty_typed_dns_configuration_is_valid(self):
        r=self.runsh('''service_properties() { echo 'a{sv} 1 "Nameservers.Configuration" as 0'; }
read_nameserver_config_checked''',dns=True)
        self.assertEqual(r.stdout,'')

    def test_connman_state_round_trip(self):
        r=self.runsh('''DNS_MODE=connman; HELPER_ADDRESS=192.0.2.20; HELPER_PORT=53
SERVICE=ethernet_fixture; INTERFACE=eth0; UPSTREAM=192.0.2.1
ORIGINAL_NAMESERVERS='192.0.2.1;2001:db8::53'; NAMESERVERS_CHANGED=1
save_state
DNS_MODE=redirect; HELPER_ADDRESS=127.0.0.1; HELPER_PORT=5354
load_state; echo "$DNS_MODE $HELPER_ADDRESS:$HELPER_PORT $ORIGINAL_NAMESERVERS $NAMESERVERS_CHANGED"''',dns=True)
        self.assertEqual(r.stdout.strip(),'connman 192.0.2.20:53 192.0.2.1;2001:db8::53 1')

    def test_connman_external_change_is_not_overwritten(self):
        r=self.runsh('''DNS_MODE=connman; NAMESERVERS_CHANGED=1; HELPER_ADDRESS=127.0.0.2
ORIGINAL_NAMESERVERS=192.0.2.1
read_nameserver_config_checked() { echo 192.0.2.99; }
set_nameserver_array() { echo UNEXPECTED_WRITE; }
connman_dns_off''',dns=True,check=False)
        self.assertEqual(r.returncode,1)
        self.assertNotIn('UNEXPECTED_WRITE',r.stdout)

    def test_connman_failed_restore_keeps_changed_flag(self):
        r=self.runsh('''DNS_MODE=connman; NAMESERVERS_CHANGED=1; HELPER_ADDRESS=127.0.0.2
ORIGINAL_NAMESERVERS=192.0.2.1
read_nameserver_config_checked() { echo 127.0.0.2; }
set_nameserver_array() { return 1; }
connman_dns_off; rc=$?; echo "$NAMESERVERS_CHANGED"; exit "$rc"''',dns=True,check=False)
        self.assertEqual(r.returncode,1)
        self.assertEqual(r.stdout.strip(),'1')

    def test_connman_enable_records_intent_before_setting_dns(self):
        r=self.runsh('''DNS_MODE=connman; HELPER_ADDRESS=127.0.0.2; ORIGINAL_NAMESERVERS=''
read_nameserver_config_checked() { echo ''; }
save_state() { echo "saved=$NAMESERVERS_CHANGED"; }
set_nameserver_array() { echo "write=$1"; return 1; }
connman_dns_on''',dns=True,check=False)
        self.assertEqual(r.returncode,1)
        self.assertEqual(r.stdout.splitlines(),['saved=1','write=127.0.0.2'])

    def test_connman_restore_dhcp_uses_empty_array(self):
        r=self.runsh('''DNS_MODE=connman; HELPER_ADDRESS=127.0.0.2; NAMESERVERS_CHANGED=1; ORIGINAL_NAMESERVERS=''
read_nameserver_config_checked() { echo 127.0.0.2; }
set_nameserver_array() { echo "arguments=$#"; }
wait_nameserver_config() { return 0; }; save_state() { :; }
connman_dns_off''',dns=True)
        self.assertIn('arguments=0',r.stdout)

    def test_connman_restore_preserves_dns_order(self):
        r=self.runsh('''DNS_MODE=connman; HELPER_ADDRESS=127.0.0.2; NAMESERVERS_CHANGED=1
ORIGINAL_NAMESERVERS='192.0.2.1;2001:db8::53'
read_nameserver_config_checked() { echo 127.0.0.2; }
set_nameserver_array() { printf 'restored:%s,%s\\n' "$1" "$2"; }
wait_nameserver_config() { return 0; }; save_state() { :; }
connman_dns_off''',dns=True)
        self.assertIn('restored:192.0.2.1,2001:db8::53',r.stdout)

    def test_connman_status_requires_effective_dns_pin(self):
        r=self.runsh('''DNS_MODE=connman; HELPER_ADDRESS=127.0.0.2; NAMESERVERS_CHANGED=1
read_nameserver_config_checked() { echo 127.0.0.2; }
read_effective_nameservers() { echo 192.0.2.1; }
network_path_active''',dns=True,check=False)
        self.assertEqual(r.returncode,1)

    def test_connman_path_does_not_call_iptables(self):
        r=self.runsh('''DNS_MODE=connman; HELPER_ADDRESS=127.0.0.2; NAMESERVERS_CHANGED=1
read_nameserver_config_checked() { echo 127.0.0.2; }
read_effective_nameservers() { echo 127.0.0.2; }
iptables() { echo UNEXPECTED_FIREWALL; return 1; }
network_path_active; nat_off''',dns=True)
        self.assertNotIn('UNEXPECTED_FIREWALL',r.stdout)

    def trial_fixture(self, fail_enable=False, fail_restore=False):
        init=self.base/'trial-init';init.mkdir()
        log=self.base/'calls'
        helper=init/'nospy-dns-filter.sh'
        helper.write_text('#!/bin/sh\necho "$1 ipv6=$NOSPY_DNS_IPV6_MODE" >> '+str(log)+'\n'+
            ('[ "$1" != enable ] || exit 1\n' if fail_enable else '')+
            ('[ "$1" != disable ] || exit 1\n' if fail_restore else '')+'exit 0\n')
        helper.chmod(0o755);(init/'nospy-dns-filter.js').touch()
        script=self.base/'trial.sh'
        source=(ROOT/'scripts/tv-dns-trial.sh').read_text().replace('[ "$(id -u)" = 0 ]','true').replace('sleep "$trial_seconds"',':')
        # Keep even the trial's scratch state inside this disposable fixture.
        source=source.replace('mkdir -p /var/lib/webosbrew || exit 1','true').replace('/var/lib/webosbrew/lgtvprivacy-dns-trial.XXXXXX',str(self.base/'trial-state.XXXXXX'))
        script.write_text(source)
        return subprocess.run(['sh',str(script),str(init),'15'],capture_output=True,text=True),log

    def test_trial_always_restores_after_success(self):
        result,log=self.trial_fixture()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(log.read_text().splitlines(),['enable ipv6=preserve','status ipv6=preserve','disable ipv6=preserve'])
        self.assertIn('TRIAL_RESTORED',result.stdout)

    def test_trial_restores_after_startup_failure(self):
        result,log=self.trial_fixture(fail_enable=True)
        self.assertEqual(result.returncode,1)
        self.assertEqual(log.read_text().splitlines(),['enable ipv6=preserve','disable ipv6=preserve'])

    def test_trial_reports_restore_failure(self):
        result,_=self.trial_fixture(fail_restore=True)
        self.assertEqual(result.returncode,1)
        self.assertIn('TRIAL_RESTORE_FAILED',result.stdout)

    def test_fresh_property_reader_initializes_webos_bus(self):
        r=self.runsh('''unset WEBOS_BUS_READY
configure_connman_bus() { WEBOS_BUS_READY=1; export WEBOS_BUS_READY; }
bounded() { "$@"; }
busctl() {
    [ "${WEBOS_BUS_READY:-0}" = 1 ] || return 1
    case "$*" in *GetProperties*) echo 'a{sv} 1 "State" s "online"' ;; *) return 1 ;; esac
}
connmanctl() { return 1; }
service_properties''',dns=True)
        self.assertIn('"State" s "online"',r.stdout)

if __name__=='__main__': unittest.main(verbosity=2)
