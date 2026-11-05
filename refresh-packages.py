#!/usr/bin/env python3
import argparse
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('archive', type=Path)
parser.add_argument('deps', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--no-xz', action='store_true')
parser.add_argument('--level', default='19')
args = parser.parse_args()
replacements = {}
for os_version, old, new in [
    ('24.04', '5.6.1+really5.4.5-1ubuntu0.3', '5.6.1+really5.4.5-1ubuntu0.4'),
    ('26.04', '5.8.3-1', '5.8.3-1ubuntu0.1'),
]:
    for arch in ('amd64', 'arm64'):
        old_name = f'{os_version}/liblzma-dev_{old}_{arch}.deb'
        new_name = f'{os_version}/liblzma-dev_{new}_{arch}.deb'
        replacements[old_name] = new_name

def digest(data):
    return hashlib.sha256(data).hexdigest()

def identity(member, data):
    return [member.type.decode('ascii'), member.mode, member.uid, member.gid,
            member.uname, member.gname, member.mtime, member.linkname,
            len(data) if member.isfile() else member.size,
            digest(data) if member.isfile() else None]

def read_archive(path):
    process = subprocess.Popen(['zstd', '-dc', str(path)], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for member in archive:
                data = archive.extractfile(member).read() if member.isfile() else b''
                yield member, data
    finally:
        process.stdout.close()
        if process.wait() != 0:
            raise RuntimeError(f'Cannot decompress {path}')

args.output.mkdir(parents=True, exist_ok=True)
expected = {}
changes = []
runtime = []
with tempfile.TemporaryDirectory(prefix='php5-lzma-') as temporary:
    plain = Path(temporary) / 'package.tar'
    with tarfile.open(plain, mode='w', format=tarfile.PAX_FORMAT) as output:
        for member, data in read_archive(args.archive):
            assert member.name not in expected, f'Duplicate member: {member.name}'
            relative = member.name.split('/deps/', 1)[-1]
            if relative in replacements:
                new_relative = replacements[relative]
                replacement = (args.deps / new_relative).read_bytes()
                changes.append({'old': member.name, 'old_sha256': digest(data),
                                'new': member.name.split('/deps/', 1)[0] + '/deps/' + new_relative,
                                'new_sha256': digest(replacement)})
                member = copy.copy(member)
                member.name = changes[-1]['new']
                member.size = len(replacement)
                data = replacement
            if member.isfile() and '-build' in member.name and member.name.endswith('.tar.zst'):
                runtime.append({'name': member.name, 'sha256': digest(data)})
            expected[member.name] = identity(member, data)
            output.addfile(member, io.BytesIO(data) if member.isfile() else None)
    assert len(changes) == 4, changes
    assert len(runtime) == 1, runtime
    destination = args.output / args.archive.name
    with destination.open('wb') as output:
        subprocess.run(['zstd', '-T2', '-' + args.level, '-c', str(plain)], stdout=output, check=True)
    actual = {member.name: identity(member, data) for member, data in read_archive(destination)}
    assert actual == expected, 'Repacked content or metadata differs'
    if not args.no_xz:
        xz = destination.with_suffix('.xz')
        with xz.open('wb') as output:
            subprocess.run(['xz', '-T2', '-6', '-c', str(plain)], stdout=output, check=True)
        subprocess.run(['xz', '-t', str(xz)], check=True)
    report = {'archive': args.archive.name, 'changed_packages': changes,
              'runtime': runtime, 'verified_members': len(actual),
              'unchanged_other_members': len(actual) - 4}
    (args.output / (args.archive.name + '.json')).write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)
