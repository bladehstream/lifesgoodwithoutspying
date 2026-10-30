"""Run only collect_domains() in an isolated shell; never run TV apply hooks."""
import itertools
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "app/init/nospy-apply.sh"


class CollectDomainsTest(unittest.TestCase):
    def test_category_selection(self):
        source = SOURCE.read_text(encoding="utf-8")
        match = re.search(r"^collect_domains\(\) \{\n.*?^\}", source, re.M | re.S)
        self.assertIsNotNone(match, "collect_domains function not found")
        shell = os.environ.get("TEST_SHELL", "sh")
        for mode, sdp, ads in itertools.product(("initial", "full"), ("on", "off"), ("on", "off")):
            with self.subTest(mode=mode, sdp=sdp, ads=ads), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "sdp.txt").write_text("# SDP fixture\nsdp.example\n\n", encoding="utf-8", newline="\n")
                (root / "ads.txt").write_text("# Ads fixture\nads.example\nads.example\n\n", encoding="utf-8", newline="\n")
                harness = '''set -eu
BLOCKDIR=.
KEYS_TMP=./keys.tmp
domain_keys() { printf '%s\\n' domains.sdp domains.ads; }
is_on() {
    case "$1" in
        domains.sdp) [ "$SDP" = on ] ;;
        domains.ads) [ "$ADS" = on ] ;;
        *) return 1 ;;
    esac
}
cat_file_for_key() {
    case "$1" in
        domains.sdp) echo sdp.txt ;;
        domains.ads) echo ads.txt ;;
    esac
}
'''
                harness += match.group(0) + '\ncollect_domains "$MODE"\n'
                (root / "test.sh").write_text(harness, encoding="utf-8", newline="\n")
                result = subprocess.run(
                    [shell, "test.sh"], cwd=tmp, capture_output=True, text=True,
                    env=dict(os.environ, MODE=mode, SDP=sdp, ADS=ads), check=True,
                )
                expected = []
                if sdp == "on" and mode != "initial":
                    expected.append("sdp.example")
                if ads == "on":
                    expected.append("ads.example")
                self.assertEqual(result.stdout.splitlines(), expected)


if __name__ == "__main__":
    unittest.main()
