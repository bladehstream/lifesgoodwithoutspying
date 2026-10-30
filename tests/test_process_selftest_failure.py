"""Exercise the actual self-test decisions with failed list producers."""
import hashlib
import itertools
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

CTL = Path(__file__).resolve().parents[1] / 'app/init/nospy-ctl.sh'
HASHES = {'voice': '15233d814be98ba1a46f38259c40b539350b8efa47e18b9593ef64ceca52450e',
          'ads': '497bbe873b6f4b26186f829e4dfe00351ec17a2e1c274a5a041b6ba9c2bf3a5e'}


class SelftestFailureTest(unittest.TestCase):
    def test_partial_target_producer_failure_is_unknown(self):
        source = CTL.read_text()
        wrapper = re.search(r'^status_write_targets\(\) \(\n.*?^\)', source, re.M | re.S)
        self.assertIsNotNone(wrapper)
        self.assertEqual(hashlib.sha256(wrapper.group().encode()).hexdigest(),
                         'f571b594640af09db6afde6ce49a7fac7ccef14de1f5951c08a69f699125f6e9')
        blocks = []
        for name in ('voice', 'ads'):
            match = re.search(r'^        ' + name + r'_state=unknown\n.*?^        rm -f "\$TMP\.' + name + r'"',
                              source, re.M | re.S)
            self.assertIsNotNone(match)
            self.assertEqual(hashlib.sha256(match.group().encode()).hexdigest(), HASHES[name])
            blocks.append(match.group())
        script = '''set -u
TMP="$TMPDIR/selftest"
voice_execs() { printf '%s\\n' /synthetic/voice; [ "$CASE" != voice_fail ]; }
ads_execs() { printf '%s\\n' /synthetic/ads; [ "$CASE" != ads_fail ]; }
process_inventory_state() { echo stopped; }
''' + wrapper.group() + '\n' + '\n'.join(blocks) + '\n'
        shells = [['sh']]
        if shutil.which('busybox'): shells.append(['busybox', 'sh'])
        cases = [('clean', '  voice: no listed process observed\n  ad processes: no listed process observed'),
                 ('voice_fail', '  voice: process scan unavailable\n  ad processes: no listed process observed'),
                 ('ads_fail', '  voice: no listed process observed\n  ad processes: process scan unavailable')]
        for shell, (case, expected) in itertools.product(shells, cases):
            with self.subTest(shell=shell, case=case), tempfile.TemporaryDirectory() as tmp:
                result = subprocess.run(shell + ['-c', script], cwd=tmp, text=True, capture_output=True,
                                        env=dict(os.environ, TMPDIR=tmp, CASE=case), check=True)
                self.assertEqual(result.stdout.rstrip(), expected)


if __name__ == '__main__':
    unittest.main()
