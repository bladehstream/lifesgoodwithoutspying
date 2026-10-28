"""Verify UPnP cleanup signals only the known stub and its known sleep child."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIB = (ROOT / 'app/init/nospy-lib.sh').read_text()

class UpnpSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name); self.proc = self.base / 'proc'; self.proc.mkdir()
        self.process(100, '/bin/sh', b'/bin/sh\0/usr/sbin/upnpd\0')
        self.process(101, '/bin/sleep', b'sleep\0' + b'2147483647\0', 100)
        self.process(102, '/bin/sleep', b'sleep\0' + b'2147483647\0', 100)
    def process(self,pid,exe,cmd,parent=None):
        p=self.proc/str(pid);p.mkdir(exist_ok=True);(p/'exe').symlink_to(exe)
        (p/'cmdline').write_bytes(cmd)
        if parent is not None: (p/'status').write_text('Name:\ttest\nPPid:\t%s\n' % parent)
    def run_shell(self, body):
        script = self.base/'test.sh'
        script.write_text(LIB + '\nUPNP_PROC_ROOT=' + str(self.proc) + '\n' + body + '\n')
        return subprocess.run(['sh',str(script)],capture_output=True,text=True,timeout=5)
    def test_only_verified_parent_and_children_are_signaled(self):
        result=self.run_shell('''
pgrep() { [ "$1" = -P ] && printf '101\\n102\\n'; }
kill() { echo "SIGNAL $*"; }
upnp_stop_owned_stub 100
''')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.splitlines(),['SIGNAL -9 101','SIGNAL -9 102','SIGNAL -9 100'])
    def test_unknown_child_prevents_all_signals(self):
        (self.proc/'102'/'cmdline').write_bytes(b'sleep\0' + b'5\0')
        result=self.run_shell('''
pgrep() { [ "$1" = -P ] && printf '101\\n102\\n'; }
kill() { echo "UNEXPECTED SIGNAL $*"; }
upnp_stop_owned_stub 100
''')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('SIGNAL',result.stdout)
    def test_wrong_parent_or_executable_is_rejected(self):
        (self.proc/'101'/'status').write_text('PPid:\t200\n')
        r=self.run_shell('upnp_stub_sleep_owned 100 101')
        self.assertNotEqual(r.returncode,0)
        (self.proc/'100'/'cmdline').write_bytes(b'/bin/sh\0/tmp/unrelated\0')
        r=self.run_shell('upnp_stub_pid_owned 100')
        self.assertNotEqual(r.returncode,0)
    def test_changed_identity_is_rechecked_before_signaling(self):
        result=self.run_shell('''
pgrep() { [ "$1" = -P ] && echo 101; }
upnp_stub_pid_owned() { return 0; }
checks=0
upnp_stub_sleep_owned() { checks=$((checks+1)); [ "$checks" = 1 ]; }
kill() { echo "UNEXPECTED SIGNAL $*"; }
upnp_stop_owned_stub 100
''')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('SIGNAL',result.stdout)
    def test_unverified_child_is_reported_as_incomplete_restore(self):
        (self.proc/'101'/'cmdline').write_bytes(b'unrelated\0')
        result=self.run_shell('''
pgrep() { case "$1" in -x) echo 100 ;; -P) echo 101 ;; esac; }
upnp_stub_active() { return 1; }
kill() { echo "UNEXPECTED SIGNAL $*"; }
upnp_unstub
''')
        self.assertEqual(result.returncode,2,result.stderr)
        self.assertIn('unverified child',result.stderr)
        self.assertNotIn('SIGNAL',result.stdout)
    def test_only_exact_real_upnp_path_is_accepted(self):
        self.process(200, '/usr/sbin/upnpd', b'upnpd\0')
        self.process(201, '/tmp/upnpd', b'upnpd\0')
        self.assertEqual(self.run_shell('upnp_real_pid_owned 200').returncode,0)
        self.assertNotEqual(self.run_shell('upnp_real_pid_owned 201').returncode,0)
    def test_unverified_cleanup_fails_restore(self):
        result = self.run_shell('''
stub_clear_all() { :; }; upnp_unstub() { return 2; }
units_restore() { echo UNEXPECTED; }; upnp_restore() { echo UNEXPECTED; }
services_restore
''')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('UNEXPECTED',result.stdout)

if __name__ == '__main__': unittest.main()
