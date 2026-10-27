#!/usr/bin/env python3
"""Normalize packager permissions, then verify source parity and metadata."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

parser=argparse.ArgumentParser()
parser.add_argument('package',type=Path)
parser.add_argument('--normalize',action='store_true')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
info=json.loads((root/'app/appinfo.json').read_text())
names=subprocess.check_output(['ar','t',str(args.package)],text=True).splitlines()
blobs={name:subprocess.check_output(['ar','p',str(args.package),name]) for name in names}
if args.normalize:
    for name in names:
        if not name.endswith('.tar.gz'): continue
        out=io.BytesIO()
        with tarfile.open(fileobj=io.BytesIO(blobs[name])) as source, tarfile.open(fileobj=out,mode='w:gz',format=tarfile.GNU_FORMAT) as dest:
            for member in source:
                executable=member.name.endswith('.sh') or member.name.endswith('/nospy-upnpd-stub') or member.name.rsplit('/',1)[-1] in ['preinst','postinst','prerm','postrm']
                member.mode=0o755 if member.isdir() or executable else 0o644
                member.uid=member.gid=0;member.uname=member.gname='root'
                dest.addfile(member,source.extractfile(member) if member.isfile() else None)
        blobs[name]=out.getvalue()
    result=bytearray(b'!<arch>\n')
    for name in names:
        blob=blobs[name]
        header=f'{name+"/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(blob):<10}`\n'.encode('ascii')
        assert len(header)==60
        result.extend(header);result.extend(blob)
        if len(blob)%2:result.extend(b'\n')
    args.package.write_bytes(result)

prefix='usr/palm/applications/'+info['id']+'/'
seen=set()
with tarfile.open(fileobj=io.BytesIO(blobs['data.tar.gz'])) as archive:
    for member in archive:
        assert not member.mode & 0o022, (member.name,'writable by group or others')
        assert not member.name.startswith('/') and '..' not in Path(member.name).parts
        if member.isfile() and member.name.startswith(prefix):
            rel=member.name[len(prefix):];seen.add(rel)
            assert (root/'app'/rel).read_bytes()==archive.extractfile(member).read(), ('source mismatch',rel)
expected={str(p.relative_to(root/'app')) for p in (root/'app').rglob('*') if p.is_file()}
assert seen==expected, ('missing/extra app files',seen^expected)
print(f'PASS: {len(seen)} app files match source; safe modes and paths; version {info["version"]}')
print(hashlib.sha256(args.package.read_bytes()).hexdigest()+'  '+str(args.package))
