"""Exercise target-list write failure handling without changing TV actions."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HASHES = {'target_paths': '78563ee034225bfa0d316ab16044d073ea3183e07f57be687a8ba2df097183ab',
          'voice_execs': '47193307a76a970d1bcf02f592f85d50bd1057774a31dfab49f19b520e3529ee',
          'ads_execs': '3b5dc0b6c677fe6afe948fb420f1e21b3406061c4cdcd099e777ab169bbc4fea',
          'status_write_targets': 'f571b594640af09db6afde6ce49a7fac7ccef14de1f5951c08a69f699125f6e9'}


class TargetWriteTest(unittest.TestCase):
    def test_early_printf_error_is_not_masked_by_later_success(self):
        lib = (ROOT / 'app/init/nospy-lib.sh').read_text()
        ctl = (ROOT / 'app/init/nospy-ctl.sh').read_text()
        functions = []
        for name in ('target_paths', 'voice_execs', 'ads_execs', 'status_write_targets'):
            source = ctl if name == 'status_write_targets' else lib
            if name == 'status_write_targets':
                pattern = r'^status_write_targets\(\) \(\n.*?^\)'
            else:
                pattern = r'^' + name + r'\(\) \{\n.*?^\}'
            match = re.search(pattern, source, re.M | re.S)
            self.assertIsNotNone(match)
            self.assertEqual(hashlib.sha256(match.group().encode()).hexdigest(), HASHES[name])
            functions.append(match.group())
        script = '''set -u
command() {
    [ "$1" = printf ] || return 5
    shift
    counter=$((counter+1))
    [ "$counter" -ne 2 ] || return 1
    /usr/bin/printf "$@"
}
printf() { command printf "$@"; }
''' + '\n'.join(functions) + '''
counter=0
"$GENERATOR" > "$TMPDIR/direct"
echo "direct_rc=$?"
counter=0
status_write_targets "$GENERATOR" > "$TMPDIR/wrapped"
echo "wrapped_rc=$?"
echo "wrapped_lines=$(wc -l < "$TMPDIR/wrapped")"
'''
        shells = [['sh']]
        if shutil.which('busybox'): shells.append(['busybox', 'sh'])
        for shell in shells:
            for generator in ('voice_execs', 'ads_execs'):
                with self.subTest(shell=shell, generator=generator), tempfile.TemporaryDirectory() as tmp:
                    result = subprocess.run(shell + ['-c', script], cwd=tmp, text=True, capture_output=True,
                                            env=dict(os.environ, TMPDIR=tmp, GENERATOR=generator), check=True)
                    self.assertEqual(result.stdout.splitlines(), ['direct_rc=0', 'wrapped_rc=1', 'wrapped_lines=2'])
        if Path('/dev/full').exists():
            real_io = '\n'.join(functions) + '''
status_write_targets "$GENERATOR" > /dev/full 2>/dev/null
echo "wrapped_rc=$?"
'''
            for shell in shells:
                for generator in ('voice_execs', 'ads_execs'):
                    with self.subTest(shell=shell, generator=generator, device='full'):
                        result = subprocess.run(shell + ['-c', real_io], text=True, capture_output=True,
                                                env=dict(os.environ, GENERATOR=generator), check=True)
                        self.assertEqual(result.stdout.strip(), 'wrapped_rc=1')


if __name__ == '__main__':
    unittest.main()
