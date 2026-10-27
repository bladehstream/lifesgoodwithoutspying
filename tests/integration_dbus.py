#!/usr/bin/env python3
"""Exercise real busctl against a fake ConnMan on a private, disposable bus."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'dns-filter/scripts/tv-handoff.sh').read_text().split('case "${1:-status}"')[0]

def run_case(initial, fail_probe=False, fresh_bus=False):
    with tempfile.TemporaryDirectory(prefix='nospy-private-bus-') as directory:
        base=Path(directory)
        address='unix:path='+str(base/'bus')
        daemon=subprocess.Popen(['dbus-daemon','--session','--nofork','--address='+address,'--print-address=1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        fake=None
        try:
            actual=daemon.stdout.readline().strip()
            if not actual: raise RuntimeError('private D-Bus daemon failed: '+daemon.stderr.read())
            fake=subprocess.Popen(['/usr/bin/python3',str(ROOT/'tests/fake_connman_bus.py'),actual,json.dumps(initial)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            if fake.stdout.readline().strip()!='READY': raise RuntimeError('fake service failed: '+fake.stderr.read())
            body='''
DNS_MODE=connman
HELPER_ADDRESS=127.0.0.2
HELPER_PORT=53
SERVICE=ethernet_fixture
INTERFACE=eth0
UPSTREAM=192.0.2.1
ORIGINAL_NAMESERVERS="$(read_nameserver_config_checked)" || exit 1
initial_dns="$ORIGINAL_NAMESERVERS"
connman_dns_on || exit 2
network_path_active || exit 3
connman_dns_off || exit 4
restored_dns="$(read_nameserver_config_checked)" || exit 5
[ "$initial_dns" = "$restored_dns" ] || exit 6
[ "$NAMESERVERS_CHANGED" = 0 ] || exit 7
'''
            if fail_probe:
                # Exercise the actual EXIT rollback and D-Bus restoration while
                # mocking root-only host operations and the failing data path.
                body = '\n'.join([
                    'require_root() { :; }; require_command() { :; }',
                    'DNS_MODE=connman; IPV6_MODE=preserve',
                    'discover_service_snapshot() { SERVICE=ethernet_fixture; SETTINGS="'+str(base/'settings')+'"; INTERFACE=eth0; UPSTREAM=192.0.2.1; LISTEN_ADDRESS=192.0.2.20; }',
                    'helper_start() { :; }; helper_stop() { :; }',
                    'probe_dns_path() { return 1; }',
                    'resolv_off() { :; }; nat_off() { :; }',
                    'enable_handoff',
                ])
            case_source=source
            if fresh_bus:
                case_source += '\nconfigure_connman_bus() { DBUS_SYSTEM_BUS_ADDRESS="$PRIVATE_TEST_BUS"; export DBUS_SYSTEM_BUS_ADDRESS; }\n'
            script=base/'case.sh';script.write_text(case_source+'\n'+body)
            env=dict(os.environ,DBUS_SYSTEM_BUS_ADDRESS=actual,NOSPY_DNS_STATE_DIR=str(base/'state'))
            if fresh_bus:
                env['PRIVATE_TEST_BUS']=actual
                env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(base/'unavailable-default-bus')
            result=subprocess.run(['sh',str(script)],env=env,capture_output=True,text=True,timeout=30)
            if fail_probe:
                if result.returncode != 1: raise RuntimeError('failed probe did not fail activation')
                if (base/'state/lifesgoodwithoutspying-dns-filter.state').exists(): raise RuntimeError('successful rollback left handoff state')
                script.write_text(source+'\nSERVICE=ethernet_fixture\nread_nameserver_config_checked\n')
                check=subprocess.run(['sh',str(script)],env=env,capture_output=True,text=True,timeout=15)
                if check.returncode or check.stdout.strip()!=';'.join(initial): raise RuntimeError('original DNS was not restored after probe failure')
                print('PASS: failed data-path probe rolled back real D-Bus configuration')
            else:
                if result.returncode:raise RuntimeError(result.stdout+result.stderr)
                print('PASS: real D-Bus pin and restore', 'fresh webOS bus selection' if fresh_bus else ('DHCP' if not initial else 'ordered IPv4/IPv6 array'))
        finally:
            for proc in [fake,daemon]:
                if proc is None:continue
                proc.terminate()
                try:proc.wait(timeout=3)
                except subprocess.TimeoutExpired:proc.kill();proc.wait()

if __name__=='__main__':
    run_case([])
    run_case(['192.0.2.1','2001:db8::53'])
    run_case([], fail_probe=True)
    run_case([], fresh_bus=True)
