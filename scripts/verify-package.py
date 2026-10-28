#!/usr/bin/env python3
"""Normalize IPK modes and verify that the packaged application matches source."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def check(condition, message):
    if not condition:
        raise ValueError(message)

def check_member(member, seen):
    name = member.name.rstrip('/')
    parts = PurePosixPath(name).parts
    check(name and not name.startswith('/') and '..' not in parts, 'unsafe path: ' + name)
    canonical = '/'.join(parts)
    check(canonical not in seen, 'duplicate archive entry: ' + name)
    seen.add(canonical)
    check(member.isfile() or member.isdir(), 'unsupported archive entry: ' + name)
    check(not member.mode & 0o7022, 'unsafe permissions: ' + name)

def process_tar(blob, normalize):
    output = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as source, \
         tarfile.open(fileobj=output, mode='w:gz', format=tarfile.GNU_FORMAT) as target:
        seen = set()
        for member in source:
            if normalize:
                executable = member.name.endswith('.sh') or member.name.endswith('/nospy-upnpd-stub') or member.name.rsplit('/', 1)[-1] in ('preinst', 'postinst', 'prerm', 'postrm')
                member.mode = 0o755 if member.isdir() or executable else 0o644
                member.uid = member.gid = 0
                member.uname = member.gname = 'root'
            check_member(member, seen)
            target.addfile(member, source.extractfile(member) if member.isfile() else None)
    return output.getvalue() if normalize else blob

def verify_data(blob, root, app_id, version):
    prefix = 'usr/palm/applications/' + app_id + '/'
    package_info = 'usr/palm/packages/' + app_id + '/packageinfo.json'
    seen, files = set(), set()
    found_metadata = False
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as archive:
        for member in archive:
            check_member(member, seen)
            if not member.isfile():
                continue
            if member.name == package_info:
                metadata = json.load(archive.extractfile(member))
                check(metadata.get('id') == app_id and metadata.get('app') == app_id and metadata.get('version') == version, 'package metadata mismatch')
                found_metadata = True
                continue
            check(member.name.startswith(prefix), 'unexpected package file: ' + member.name)
            rel = member.name[len(prefix):]
            path = root / 'app' / rel
            check(path.is_file() and not path.is_symlink(), 'source file missing or symlink: ' + rel)
            check(path.read_bytes() == archive.extractfile(member).read(), 'source mismatch: ' + rel)
            files.add(rel)
    expected = {p.relative_to(root / 'app').as_posix() for p in (root / 'app').rglob('*') if p.is_file()}
    check(files == expected, 'missing or extra application files: ' + repr(files ^ expected))
    check(found_metadata, 'package metadata missing')
    return len(files)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('package', type=Path)
    parser.add_argument('--normalize', action='store_true')
    args = parser.parse_args()
    info = json.loads((ROOT / 'app/appinfo.json').read_text())
    names = subprocess.check_output(['ar', 't', str(args.package)], text=True).splitlines()
    check(names == ['debian-binary', 'control.tar.gz', 'data.tar.gz'], 'unexpected IPK members')
    blobs = {name: subprocess.check_output(['ar', 'p', str(args.package), name]) for name in names}
    check(blobs['debian-binary'] == b'2.0\n', 'unexpected IPK version')
    for name in ('control.tar.gz', 'data.tar.gz'):
        blobs[name] = process_tar(blobs[name], args.normalize)
    count = verify_data(blobs['data.tar.gz'], ROOT, info['id'], info['version'])
    if args.normalize:
        result = bytearray(b'!<arch>\n')
        for name in names:
            blob = blobs[name]
            header = f'{name+"/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(blob):<10}`\n'.encode('ascii')
            check(len(header) == 60, 'invalid ar header')
            result.extend(header); result.extend(blob)
            if len(blob) % 2: result.extend(b'\n')
        with tempfile.NamedTemporaryFile(dir=args.package.parent, delete=False) as tmp:
            temporary = tmp.name
            try:
                tmp.write(result)
                tmp.flush()
                os.chmod(temporary, args.package.stat().st_mode & 0o777)
                os.replace(temporary, args.package)
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
    print(f'PASS: {count} app files match source; safe modes and paths; version {info["version"]}')
    print(hashlib.sha256(args.package.read_bytes()).hexdigest() + '  ' + str(args.package))

if __name__ == '__main__':
    main()
