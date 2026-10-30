"""Run only the read-only process classifier against synthetic listings."""
import hashlib
import itertools
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'app/init/nospy-lib.sh'


class ProcessInventoryTest(unittest.TestCase):
    def test_scan_failures_do_not_look_stopped(self):
        match = re.search(r'^process_inventory_state\(\) \{\n.*?^\}', LIB.read_text(), re.M | re.S)
        self.assertIsNotNone(match)
        # This isolated test executes the extracted function with stubbed ls.
        # Pinning prevents unreviewed future edits from executing here.
        expected_hash = '8e2dfe2748efab211a1dcc7f952e0eaf2a5dead6d3480e72dddc973a1f0c62a0'
        self.assertEqual(hashlib.sha256(match.group().encode()).hexdigest(), expected_hash)
        harness = '''set -eu
ls() {
 case "$CASE" in
  clean|awkfail) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/123/exe -> /usr/sbin/other' ;;
  running) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/123/exe -> /usr/sbin/synthetic-voice' ;;
  partial) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/123/exe -> /usr/sbin/other'; return 1 ;;
  partial_running) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/123/exe -> /usr/sbin/synthetic-voice'; return 1 ;;
  kernel|user_without_exe|badstat|missingstat) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/456/exe'; printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/123/exe -> /usr/sbin/other' ;;
  malformed) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/123/exe' ;;
  empty) return 0 ;;
 esac
}
awk() { if [ "$CASE" = awkfail ]; then echo stopped; return 1; fi; command awk "$@"; }
''' + match.group() + '\nprocess_inventory_state "$TARGETS" "$FAKE_PROC"\n'
        shells = [['sh']]
        if shutil.which('busybox'):
            shells.append(['busybox', 'sh'])
        cases = [('clean', 'stopped'), ('running', 'running'), ('partial', 'unknown'),
                 ('malformed', 'unknown'), ('empty', 'unknown'), ('awkfail', 'unknown'),
                 ('partial_running', 'running'), ('kernel', 'stopped'),
                 ('user_without_exe', 'unknown'), ('badstat', 'unknown'), ('missingstat', 'unknown')]
        for shell, (case, expected) in itertools.product(shells, cases):
            with self.subTest(shell=shell, case=case), tempfile.TemporaryDirectory() as tmp:
                targets = Path(tmp) / 'targets'
                targets.write_text('/usr/sbin/synthetic-voice\n')
                proc = Path(tmp) / 'proc'
                (proc / '456').mkdir(parents=True)
                if case != 'missingstat':
                    flags = {'kernel': '2097152', 'user_without_exe': '0', 'badstat': 'invalid'}.get(case, '0')
                    (proc / '456/stat').write_text('456 (worker (odd) name) S 1 2 3 4 5 ' + flags + ' 0\n')
                result = subprocess.run(shell + ['-c', harness], cwd=tmp, text=True, capture_output=True,
                    env=dict(os.environ, CASE=case, TARGETS=str(targets), FAKE_PROC=str(proc)), check=True)
                self.assertEqual(result.stdout.strip(), expected)
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['sh', '-c', harness], cwd=tmp, text=True, capture_output=True,
                env=dict(os.environ, CASE='clean', TARGETS=str(Path(tmp) / 'missing'), FAKE_PROC=str(Path(tmp) / 'proc')), check=True)
            self.assertEqual(result.stdout.strip(), 'unknown')
            empty = Path(tmp) / 'empty'
            empty.write_text('')
            result = subprocess.run(['sh', '-c', harness], cwd=tmp, text=True, capture_output=True,
                env=dict(os.environ, CASE='clean', TARGETS=str(empty), FAKE_PROC=str(Path(tmp) / 'proc')), check=True)
            self.assertEqual(result.stdout.strip(), 'unknown')


if __name__ == '__main__':
    unittest.main()
