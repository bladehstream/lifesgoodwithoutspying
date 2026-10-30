"""Check that the UI string keys in index.html, app.js and i18n.js agree."""
import html
from pathlib import Path
import re
import sys
import unittest


APP = Path(__file__).resolve().parents[1] / "app"


def read(name):
    return (APP / name).read_text(encoding="utf-8")


def js_string(raw):
    """Decode the escapes i18n.js uses inside single-quoted strings."""
    return re.sub(r"\\(.)", lambda m: "\n" if m.group(1) == "n" else m.group(1), raw)


def load_strings():
    """Read each language block of i18n.js, one 'key': 'value' entry per line."""
    source = read("i18n.js")
    body = re.search(r"var STRINGS = \{\n(.*?)^    \};", source, re.M | re.S)
    if body is None:
        raise AssertionError("STRINGS table not found in i18n.js")
    strings = {}
    for lang, block in re.findall(r"^        (\w+): \{\n(.*?)^        \}", body.group(1), re.M | re.S):
        strings[lang] = {
            key: js_string(value)
            for key, value in re.findall(r"^\s+'([\w.]+)': '((?:[^'\\]|\\.)*)',?$", block, re.M)
        }
    return strings


class I18nTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.strings = load_strings()
        cls.en = cls.strings["en"]
        cls.html = read("index.html")
        cls.app = read("app.js")

    def html_keys(self):
        return re.findall(r'data-i18n(?:-label)?="([^"]+)"', self.html)

    def app_keys(self):
        # i18n keys share a handful of prefixes that no toggle data-key uses,
        # so any app.js literal starting with one of them is a key.
        prefixes = {key.split(".")[0] for key in self.en}
        return [key for key in re.findall(r"'([\w]+\.[\w.]+)'", self.app)
                if key.split(".")[0] in prefixes]

    def test_used_keys_exist(self):
        for key in self.html_keys() + self.app_keys():
            with self.subTest(key=key):
                self.assertTrue(key in self.en, "%s is not in the English table" % key)

    def test_no_unused_keys(self):
        used = set(self.html_keys()) | set(self.app_keys()) | set(re.findall(r"t\('([\w.]+)'", read("i18n.js")))
        self.assertEqual(sorted(set(self.en) - used), [])

    def test_every_layer_is_marked(self):
        for key in re.findall(r'class="layer" data-key="([^"]+)"', self.html):
            with self.subTest(layer=key):
                self.assertIn('data-i18n="layer.%s.title"' % key, self.html)
                self.assertIn('data-i18n="layer.%s.detail"' % key, self.html)

    def test_html_fallback_matches_english(self):
        # The markup keeps English text so the page reads sensibly before the
        # script runs; it must match the table or English would flip on load.
        for key, text in re.findall(r'data-i18n="([^"]+)">(.*?)</', self.html, re.S):
            text = html.unescape(re.sub(r"\s*<br\s*/?>\s*", "\n", text))
            with self.subTest(key=key):
                self.assertEqual(text, self.en.get(key))

    def test_translations_match_english_keys(self):
        for lang, table in self.strings.items():
            with self.subTest(lang=lang):
                self.assertEqual(sorted(set(table) - set(self.en)), [], "keys not in the English table")
                for key, value in table.items():
                    self.assertEqual(sorted(re.findall(r"\{\w+\}", value)),
                                     sorted(re.findall(r"\{\w+\}", self.en[key])),
                                     "placeholders differ for " + key)
                # A missing translation falls back to English at runtime, so it
                # is reported rather than failed: contributors adding a string
                # cannot be expected to supply every language.
                missing = sorted(set(self.en) - set(table))
                if missing:
                    print("\n%s: %d untranslated: %s" % (lang, len(missing), ", ".join(missing)), file=sys.stderr)


if __name__ == "__main__":
    unittest.main()
