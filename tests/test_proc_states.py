"""Run proc_states() against fixture paths and a fixture process table."""
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest


LIB = Path(__file__).resolve().parents[1] / "app/init/nospy-lib.sh"

# Two groups over fixture files. "gone" has no file; "jailed" runs from a jail
# copy while its host path also exists; "deleted" runs from a path that is no
# longer on disk.
HARNESS = '''set -eu
. "$LIB"
SERVICE_GROUPS="alpha beta"
group_targets() {
    case "$1" in
        alpha) printf '%s\\n' "up $ROOT/up" "idle $ROOT/idle" "gone $ROOT/gone" \\
                              "jailed $ROOT/jailed" "jailed $ROOT/jail/jailed" ;;
        beta) printf '%s\\n' "deleted $ROOT/deleted" "lg.dotted $ROOT/lg.dotted" ;;
        *) return 1 ;;
    esac
}
proc_exe_table() {
    case "$SCAN" in
        ok) printf '%s\\n' "1 /bin/sh" "40 $ROOT/up" "41 $ROOT/jail/jailed" "42 $ROOT/deleted" ;;
        empty) : ;;
        failed) return 1 ;;
    esac
}
proc_states "$ROOT/scratch"
'''


def run(scan):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "jail").mkdir()
        for name in ("up", "idle", "jailed", "jail/jailed", "lg.dotted"):
            (root / name).write_text("", encoding="utf-8")
        env = dict(os.environ, LIB=str(LIB), ROOT=tmp, SCAN=scan)
        out = subprocess.run(
            [os.environ.get("TEST_SHELL", "sh"), "-c", HARNESS],
            env=env, capture_output=True, text=True, check=True,
        ).stdout
        leftovers = sorted(p.name for p in root.iterdir() if p.name.startswith("scratch"))
    return out.splitlines(), leftovers


class ProcStatesTest(unittest.TestCase):
    def test_scan_ok(self):
        lines, leftovers = run("ok")
        self.assertEqual(lines, [
            "proc.alpha.up=running",
            "proc.alpha.idle=stopped",
            "proc.alpha.gone=absent",
            "proc.alpha.jailed=running",
            "proc.beta.deleted=running",
            "proc.beta.lg.dotted=stopped",
            "alpha=running",
            "beta=running",
            "proc_scan=ok",
        ])
        self.assertEqual(leftovers, [])

    def test_scan_failure_is_unknown_not_stopped(self):
        # An empty table and a failed one both mean the scan didn't work: a
        # binary that exists can't be called stopped. Absent stays absent.
        for scan in ("empty", "failed"):
            with self.subTest(scan=scan):
                lines, _ = run(scan)
                self.assertEqual(lines, [
                    "proc.alpha.up=unknown",
                    "proc.alpha.idle=unknown",
                    "proc.alpha.gone=absent",
                    "proc.alpha.jailed=unknown",
                    "proc.beta.deleted=absent",
                    "proc.beta.lg.dotted=unknown",
                    "alpha=unknown",
                    "beta=unknown",
                    "proc_scan=failed",
                ])


class HostsWaitTest(unittest.TestCase):
    """hosts_wait_seconds() reads the SDP worker's start from /proc."""

    def wait(self, pending):
        with tempfile.TemporaryDirectory() as tmp:
            harness = '''set -eu
. "$LIB"
HOSTS_PENDING="$TMPDIR_/pending"
CLOCK_SYNC_DELAY=60
sleep 30 &
worker=$!
case "$PENDING" in
    live) echo "$worker token" > "$HOSTS_PENDING" ;;
    dead) echo "999999999 token" > "$HOSTS_PENDING" ;;
esac
hosts_wait_seconds
kill "$worker"
'''
            env = dict(os.environ, LIB=str(LIB), TMPDIR_=tmp, PENDING=pending)
            out = subprocess.run([os.environ.get("TEST_SHELL", "sh"), "-c", harness],
                                 env=env, capture_output=True, text=True, check=True).stdout
        return int(out.strip())

    def test_counts_down_from_the_delay(self):
        self.assertIn(self.wait("live"), (59, 60))

    def test_no_worker_is_zero(self):
        self.assertEqual(self.wait("none"), 0)
        self.assertEqual(self.wait("dead"), 0)


class PendingHostsTest(unittest.TestCase):
    """The SDP worker's pending file, read through pending_read()."""

    def run_case(self, script):
        with tempfile.TemporaryDirectory() as tmp:
            harness = '''set -u
. "$LIB"
HOSTS_PENDING="$TMPDIR_/pending"
sleep 30 &
worker=$!
''' + script + '''
kill "$worker"
'''
            env = dict(os.environ, LIB=str(LIB), TMPDIR_=tmp)
            return subprocess.run([os.environ.get("TEST_SHELL", "sh"), "-c", harness],
                                  env=env, capture_output=True, text=True, check=True).stdout.split()

    def test_token_rules(self):
        out = self.run_case('''
pending_hosts_current tok; echo "none-current=$?"
pending_hosts_clear tok; echo "none-clear=$?"
hosts_pending; echo "none-pending=$?"
echo "$worker tok" > "$HOSTS_PENDING"
pending_hosts_current tok; echo "current=$?"
pending_hosts_current other; echo "other-current=$?"
hosts_pending; echo "pending=$?"
pending_hosts_clear other; [ -f "$HOSTS_PENDING" ]; echo "kept-after-other=$?"
pending_hosts_clear tok; [ -f "$HOSTS_PENDING" ]; echo "kept-after-own=$?"
echo "$worker tok" > "$HOSTS_PENDING"
pending_hosts_cancel; [ -f "$HOSTS_PENDING" ]; echo "kept-after-cancel=$?"
''')
        self.assertEqual(out, ["none-current=1", "none-clear=0", "none-pending=1", "current=0",
                               "other-current=1", "pending=0", "kept-after-other=0",
                               "kept-after-own=1", "kept-after-cancel=1"])


class SelftestProcessesTest(unittest.TestCase):
    """selftest_processes() in nospy-ctl.sh summarises proc_states output."""

    def test_every_group_is_reported(self):
        ctl = (LIB.parent / "nospy-ctl.sh").read_text(encoding="utf-8")
        fn = re.search(r"^selftest_processes\(\) \{\n.*?^\}", ctl, re.M | re.S).group(0)
        states = "\n".join([
            "proc.voice.nlpmanager=running", "proc.voice.voiceinput=stopped",
            "proc.ads.acr2=unknown", "proc.ads.lg.thinqai.adapter=unknown",
            "proc.lan.upnpd=absent", "voice=running", "ads=unknown", "lan=stopped", "proc_scan=ok",
        ]) + "\n"
        out = subprocess.run([os.environ.get("TEST_SHELL", "sh"), "-c", fn + "\nselftest_processes"],
                             input=states, capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.splitlines(), [
            "  voice: running (protection NOT active): nlpmanager",
            "  ads: unknown (process scan failed): acr2 lg.thinqai.adapter",
            "  lan: stopped",
        ])


if __name__ == "__main__":
    unittest.main()
