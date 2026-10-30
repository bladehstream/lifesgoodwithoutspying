"""Run the status producer's process block with synthetic listing fixtures."""
import hashlib
import itertools
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StatusProducerTest(unittest.TestCase):
    def test_process_status_branch(self):
        lib = (ROOT / 'app/init/nospy-lib.sh').read_text()
        ctl = (ROOT / 'app/init/nospy-ctl.sh').read_text()
        classifier = re.search(r'^process_inventory_state\(\) \{\n.*?^\}', lib, re.M | re.S)
        wrapper = re.search(r'^status_write_targets\(\) \(\n.*?^\)', ctl, re.M | re.S)
        branch = re.search(r'^        if status_write_targets voice_execs > "\$TMP.voice"; then\n.*?^        rm -f "\$TMP.voice" "\$TMP.ads"', ctl, re.M | re.S)
        self.assertIsNotNone(classifier)
        self.assertIsNotNone(branch)
        self.assertIsNotNone(wrapper)
        self.assertEqual(hashlib.sha256(wrapper.group().encode()).hexdigest(),
                         'f571b594640af09db6afde6ce49a7fac7ccef14de1f5951c08a69f699125f6e9')
        expected_classifier = '8e2dfe2748efab211a1dcc7f952e0eaf2a5dead6d3480e72dddc973a1f0c62a0'
        expected_branch = '35046f1076cb8ab9fffee7ec2b8a5e0d473bfbd87f4e93122d7204518ef63790'
        self.assertEqual(hashlib.sha256(classifier.group().encode()).hexdigest(), expected_classifier)
        self.assertEqual(hashlib.sha256(branch.group().encode()).hexdigest(), expected_branch)
        script = '''set -u
TMP="$TMPDIR/status"
voice_execs() { printf '%s\\n' /synthetic/voice; [ "$CASE" != voice_write_fail ]; }
ads_execs() { printf '%s\\n' /synthetic/ads; [ "$CASE" != ads_write_fail ]; }
ls() {
 case "$CASE" in
  clean|voice_write_fail|ads_write_fail) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/100/exe -> /synthetic/other' ;;
  voice) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/100/exe -> /synthetic/voice' ;;
  ads) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/100/exe -> /synthetic/ads' ;;
  partial) printf '%s\\n' 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/100/exe -> /synthetic/other'; return 1 ;;
 esac
}
''' + classifier.group() + '\n' + wrapper.group() + '\n' + branch.group() + '\n'
        cases = [('clean', 'voice=stopped\nads=stopped'), ('voice', 'voice=running\nads=stopped'),
                 ('ads', 'voice=stopped\nads=running'), ('partial', 'voice=unknown\nads=unknown'),
                 ('voice_write_fail', 'voice=unknown\nads=stopped'),
                 ('ads_write_fail', 'voice=stopped\nads=unknown')]
        shells = [['sh']]
        if shutil.which('busybox'):
            shells.append(['busybox', 'sh'])
        for shell, (case, expected) in itertools.product(shells, cases):
            with self.subTest(shell=shell, case=case), tempfile.TemporaryDirectory() as tmp:
                result = subprocess.run(shell + ['-c', script], cwd=tmp, text=True, capture_output=True,
                    env=dict(os.environ, TMPDIR=tmp, CASE=case), check=True)
                self.assertEqual(result.stdout.strip(), expected)
                expected_verdict = 'verdict.protected' if case == 'clean' else 'verdict.statusAttention'
                subprocess.run(['node', str(ROOT / 'tests/test_process_verdict.js'),
                    str(ROOT / 'app/app.js'), '--stdin', expected_verdict], input=result.stdout,
                    text=True, capture_output=True, check=True)


if __name__ == '__main__':
    unittest.main()
