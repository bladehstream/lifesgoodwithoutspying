import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('verify_package', Path(__file__).resolve().parents[1] / 'scripts/verify-package.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def archive(entries):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w:gz') as tar:
        for name, content, kind in entries:
            member = tarfile.TarInfo(name)
            if kind == 'link':
                member.type = tarfile.SYMTYPE
                member.linkname = '../../outside'
                tar.addfile(member)
            else:
                member.size = len(content)
                tar.addfile(member, io.BytesIO(content))
    return out.getvalue()


class PackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'app').mkdir()
        (self.root / 'app/app.js').write_bytes(b'original')
        self.app = 'ooo.example.app'
        self.prefix = 'usr/palm/applications/' + self.app + '/'
        self.metadata = 'usr/palm/packages/' + self.app + '/packageinfo.json'
        self.entries = [(self.prefix + 'app.js', b'original', 'file'),
                        (self.metadata, json.dumps({'id': self.app, 'app': self.app, 'version': '1.0'}).encode(), 'file')]

    def tearDown(self):
        self.temp.cleanup()

    def run_check(self, entries):
        return verify.verify_data(archive(entries), self.root, self.app, '1.0')

    def test_matching_package(self):
        self.assertEqual(self.run_check(self.entries), 1)

    def test_source_mismatch_and_missing_are_rejected(self):
        with self.assertRaises(ValueError):
            self.run_check([(self.prefix + 'app.js', b'changed', 'file'), self.entries[1]])
        with self.assertRaises(ValueError):
            self.run_check([self.entries[1]])

    def test_unsafe_paths_and_links_are_rejected(self):
        for entry in [('../escape', b'x', 'file'), ('/absolute', b'x', 'file'), (self.prefix + 'link', b'', 'link')]:
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                self.run_check(self.entries + [entry])

    def test_duplicate_extra_and_bad_metadata_are_rejected(self):
        for entries in [self.entries + [self.entries[0]], self.entries + [('usr/extra', b'x', 'file')],
                        [self.entries[0], (self.metadata, b'{"version":"wrong"}', 'file')]]:
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                self.run_check(entries)

    def test_unsafe_modes_are_rejected_even_with_python_optimization(self):
        member = tarfile.TarInfo('unsafe')
        member.mode = 0o666
        with self.assertRaises(ValueError):
            verify.check_member(member, set())

if __name__ == '__main__':
    unittest.main()
