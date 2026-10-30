"""Test selected-list status against temporary synthetic settings and files."""
import itertools
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DomainListStatusTest(unittest.TestCase):
    def test_selected_list_evidence_and_failures(self):
        source = (ROOT / 'app/init/nospy-ctl.sh').read_text()
        wrapper = re.search(r'^status_write_targets\(\) \(\n.*?^\)', source, re.M | re.S)
        function = re.search(r'^domain_lists_status\(\) \(\n.*?^\)', source, re.M | re.S)
        self.assertIsNotNone(wrapper)
        self.assertIsNotNone(function)
        script = '''set -u
DIR="$FIXTURE"
TMP="$FIXTURE/tmp"
CONF="$FIXTURE/config"
domain_keys() { printf '%s\\n' domains.a; [ "$CASE" != partial_keys ] || return 1; printf '%s\\n' domains.b; }
conf_default() { [ "$CASE" = disabled ] && echo off || echo on; }
cat_file_for_key() { case "$1" in domains.a) echo a.txt;; domains.b) echo b.txt;; *) return 1;; esac; }
mktemp() { [ "$CASE" != mktempfail ] || return 1; command mktemp "$@"; }
cat() { [ "$CASE" != badread ] || return 1; command cat "$@"; }
awk() { [ "$CASE" != badparse ] || return 1; command awk "$@"; }
''' + wrapper.group() + '\n' + function.group() + '\ndomain_lists_status\n'
        cases = {'enabled': 'ok:domains.a,domains.b', 'disabled': 'none',
                 'partial_keys': 'unavailable', 'mktempfail': 'unavailable', 'badread': 'unavailable',
                 'badparse': 'unavailable', 'missing': 'unavailable',
                 'empty': 'unavailable', 'invalid': 'unavailable',
                 'duplicate': 'unavailable', 'mixed': 'ok:domains.a'}
        shells = [['sh']]
        if shutil.which('busybox'):
            shells.append(['busybox', 'sh'])
        for shell, (case, expected) in itertools.product(shells, cases.items()):
            with self.subTest(shell=shell, case=case), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                lists = root / 'blocklist.d'
                lists.mkdir()
                (lists / 'a.txt').write_text('# comment\na.example\n')
                if case != 'missing':
                    (lists / 'b.txt').write_text('# empty\n' if case == 'empty' else 'b.example\n')
                config = root / 'config'
                if case in ('badread', 'badparse'):
                    config.write_text('domains.a=on\n')
                elif case == 'invalid':
                    config.write_text('domains.a=maybe\n')
                elif case == 'duplicate':
                    config.write_text('domains.a=on\ndomains.a=off\n')
                elif case == 'mixed':
                    config.write_text('domains.a=on\ndomains.b=off\n')
                result = subprocess.run(shell + ['-c', script], cwd=tmp, capture_output=True,
                    text=True, check=True, env=dict(os.environ, FIXTURE=tmp, CASE=case))
                self.assertEqual(result.stdout.strip(), expected)
                self.assertEqual(list(root.glob("tmp.domain.*")), [])


if __name__ == '__main__':
    unittest.main()
