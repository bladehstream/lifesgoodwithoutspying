"""Check DNS helper signal identity without touching the TV or host network."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import time
import shutil

ROOT=Path(__file__).resolve().parents[1]
DNS=(ROOT/'dns-filter/scripts/tv-handoff.sh').read_text().split('case "${1:-status}"')[0]

class HelperSafety(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
    def runsh(self,body,dns=False,check=True):
        source=DNS.replace('/var/lib/webosbrew',str(self.base/'state'))
        script=self.base/'case.sh';script.write_text(source+'\n'+body+'\n')
        result=subprocess.run(['sh',str(script)],capture_output=True,text=True,timeout=10)
        if check: self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        return result
    def test_helper_pid_requires_exact_node_and_bundle(self):
        node=shutil.which('node')
        if not node: self.skipTest('node is unavailable')
        bundle=self.base/'nospy-dns-filter.js';bundle.write_text('setInterval(function(){}, 1000);')
        wrong=self.base/'nospy-dns-filter-other.js';wrong.write_text(bundle.read_text())
        for script,expected in ((bundle,True),(wrong,False)):
            proc=subprocess.Popen([node,str(script)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                time.sleep(.1)
                body="mkdir -p \"$STATE_DIR\"; echo "+str(proc.pid)+" > \"$PID_FILE\"; BUNDLE='"+str(bundle)+"'; NODE='"+str(node)+"'; helper_pid"
                result=self.runsh(body,dns=True,check=False)
                self.assertEqual(result.returncode==0,expected,result.stdout+result.stderr)
            finally:
                proc.terminate();proc.wait(timeout=3)
    def test_helper_stop_never_kills_reused_pid(self):
        r=self.runsh('''
mkdir -p "$STATE_DIR"; echo 123 > "$PID_FILE"
helper_pid() {
    n=0; [ ! -f "$STATE_DIR/count" ] || n=$(cat "$STATE_DIR/count")
    echo $((n+1)) > "$STATE_DIR/count"
    [ "$n" = 0 ] && echo 123 || echo 456
}
kill() { echo "SIGNAL $*"; }; sleep() { :; }
helper_stop
''',dns=True)
        self.assertNotIn('SIGNAL',r.stdout)
    def test_helper_stop_force_kills_only_reverified_helper(self):
        r=self.runsh('''
mkdir -p "$STATE_DIR"; echo 123 > "$PID_FILE"
helper_pid() {
    n=0; [ ! -f "$STATE_DIR/count" ] || n=$(cat "$STATE_DIR/count")
    echo $((n+1)) > "$STATE_DIR/count"
    [ "$n" -lt 7 ] && echo 123 || return 1
}
kill() { echo "SIGNAL $*"; }; sleep() { :; }
helper_stop
[ ! -e "$PID_FILE" ]
''',dns=True)
        self.assertIn('SIGNAL 123',r.stdout)
        self.assertIn('SIGNAL -KILL 123',r.stdout)
    def test_helper_stop_retains_records_when_owned_helper_will_not_die(self):
        r=self.runsh('''
mkdir -p "$STATE_DIR"; echo 123 > "$PID_FILE"; touch "$STATUS_FILE"
helper_pid() { echo 123; }; kill() { :; }; sleep() { :; }
helper_stop; rc=$?
[ -f "$PID_FILE" ] && [ -f "$STATUS_FILE" ] || exit 7
[ "$rc" = 1 ] || exit 8
exit 0
''',dns=True,check=False)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
