"""Connect actual configuration, status-list producer and frontend verdict locally."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DomainStatusIntegrationTest(unittest.TestCase):
    def test_defaults_and_missing_selected_category(self):
        ctl = (ROOT / 'app/init/nospy-ctl.sh').read_text()
        wrapper = re.search(r'^status_write_targets\(\) \(\n.*?^\)', ctl, re.M | re.S)
        function = re.search(r'^domain_lists_status\(\) \(\n.*?^\)', ctl, re.M | re.S)
        self.assertIsNotNone(wrapper)
        self.assertIsNotNone(function)
        script = '''set -eu
. "$LIB"
DIR="$FIXTURE"
TMP="$FIXTURE/scratch"
CONF="$FIXTURE/config"
''' + wrapper.group() + '\n' + function.group() + '''
printf 'domain_lists='; domain_lists_status
for key in $(domain_keys); do printf '%s=%s\\n' "$key" "$(conf_get "$key")"; done
'''
        shells = [['sh']]
        if shutil.which('busybox'):
            shells.append(['busybox', 'sh'])
        for shell in shells:
            with self.subTest(shell=shell), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp)
                shutil.copytree(ROOT / 'app/init/blocklist.d', root / 'blocklist.d')
                env=dict(os.environ, LIB=str(ROOT / 'app/init/nospy-lib.sh'), FIXTURE=tmp)
                def check(expected):
                    status=subprocess.run(shell + ['-c',script], cwd=tmp, env=env,
                        check=True, text=True, capture_output=True).stdout
                    subprocess.run(['node',str(ROOT/'tests/test_domain_verdict.js'),
                        str(ROOT/'app/app.js'),'--stdin',expected], input=status, text=True,
                        capture_output=True, check=True)
                    return status
                status=check('verdict.protected')
                self.assertIn('domains.acr=on\n',status)
                self.assertIn('domain_lists=ok:',status)
                (root / 'blocklist.d/20-acr.txt').unlink()
                status=check('verdict.domainAttention')
                self.assertIn('domain_lists=unavailable\n',status)


if __name__ == '__main__':
    unittest.main()
