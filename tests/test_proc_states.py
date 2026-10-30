"""Run proc_states() against fixture paths and a fixture process table."""
import os
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


if __name__ == "__main__":
    unittest.main()
