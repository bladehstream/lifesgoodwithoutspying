"""Check listed executable matching when a jail path is no longer visible."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

LIB = Path(__file__).resolve().parents[1] / 'app/init/nospy-lib.sh'


class ProcessJailTest(unittest.TestCase):
    def test_deleted_and_unexpanded_jail_targets_are_not_reported_stopped(self):
        match = re.search(r'^process_inventory_state\(\) \{\n.*?^\}', LIB.read_text(), re.M | re.S)
        self.assertIsNotNone(match)
        # Only execute the reviewed extracted scanner with a synthetic listing.
        expected_hash = '8e2dfe2748efab211a1dcc7f952e0eaf2a5dead6d3480e72dddc973a1f0c62a0'
        self.assertEqual(hashlib.sha256(match.group().encode()).hexdigest(), expected_hash)
        harness = '''set -eu
ls() { printf '%s\\n' "$FAKE_LISTING"; }
''' + match.group() + '\nprocess_inventory_state "$TARGETS" "$TMPDIR"\n'
        shells = [['sh']]
        if shutil.which('busybox'): shells.append(['busybox', 'sh'])
        cases = (
            ('/var/palm/jail/app/usr/sbin/synthetic-voice (deleted)', 'running'),
            ('/var/palm/jail/app/usr/sbin/synthetic-voice', 'running'),
            ('/var/palm/jail/app/usr/bin/synthetic-voice', 'running'),
            ('/var/palm/jail/app/usr/sbin/synthetic-other', 'stopped'),
            ('/var/palm/jail/app/usr/sbin/synthetic-voice-extra', 'stopped'),
            ('/var/palm/jail/nested/app/usr/sbin/synthetic-voice', 'unknown'),
        )
        for shell in shells:
            for target, expected in cases:
                for jail_entry in ('/var/palm/jail/*/usr/sbin/synthetic-voice',
                                   '/var/palm/jail/other/usr/sbin/synthetic-voice'):
                    with self.subTest(shell=shell, target=target, jail_entry=jail_entry), tempfile.TemporaryDirectory() as tmp:
                        targets = Path(tmp) / 'targets'
                        # The glob may remain literal, or expand only to another jail.
                        targets.write_text('/usr/sbin/synthetic-voice\n/usr/bin/synthetic-voice\n'
                                           + jail_entry + '\n')
                        listing = 'lrwxrwxrwx 1 root root 0 Jan 1 00:00 /proc/123/exe -> ' + target
                        result = subprocess.run(shell + ['-c', harness], cwd=tmp, capture_output=True,
                            text=True, check=True, env=dict(os.environ, TMPDIR=tmp, TARGETS=str(targets),
                                                           FAKE_LISTING=listing))
                        self.assertEqual(result.stdout.strip(), expected)


if __name__ == '__main__':
    unittest.main()
