import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time


libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
libc.listxattr.restype = ctypes.c_ssize_t
libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                        ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
libc.getxattr.restype = ctypes.c_ssize_t


def xattrs(file):
    # Darwin's NOFOLLOW API inspects links themselves; Python exposes this API
    # only on Linux. Values are hashed without printing their contents.
    path = os.fsencode(file)
    length = libc.listxattr(path, None, 0, 1)
    if length < 0:
        raise OSError(ctypes.get_errno(), str(file))
    if length == 0:
        return {}
    names = ctypes.create_string_buffer(length)
    count = libc.listxattr(path, names, length, 1)
    if count < 0:
        raise OSError(ctypes.get_errno(), str(file))
    result = {}
    for name in sorted(part for part in names.raw[:count].split(b'\0') if part):
        size = libc.getxattr(path, name, None, 0, 0, 1)
        if size < 0:
            raise OSError(ctypes.get_errno(), str(file))
        data = ctypes.create_string_buffer(max(1, size))
        read = libc.getxattr(path, name, data, size, 0, 1)
        if read < 0:
            raise OSError(ctypes.get_errno(), str(file))
        result[os.fsdecode(name)] = hashlib.sha256(data.raw[:read]).hexdigest()
    return result


def digest(file):
    result = hashlib.sha256()
    with file.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def inventory(root):
    files, inodes = {}, {}
    for file in sorted(root.rglob('*')):
        info = file.lstat()
        relative = str(file.relative_to(root))
        row = {'type': stat.S_IFMT(info.st_mode), 'mode': stat.S_IMODE(info.st_mode),
               'flags': info.st_flags}
        if file.is_symlink():
            row['target'] = os.readlink(file)
        elif file.is_file():
            row.update(bytes=info.st_size, sha256=digest(file))
            inodes.setdefault((info.st_dev, info.st_ino), []).append(relative)
        row['xattrs'] = xattrs(file)
        files[relative] = row
    return {'files': files, 'hardlinks': sorted(sorted(group) for group in inodes.values() if len(group) > 1)}


def commands(mode, archive, destination):
    if mode == 'tar':
        return [['/usr/bin/tar', '--ignore-zeros', '-xkmpf', str(archive),
                 '--no-same-owner', '--numeric-owner', '-C', str(destination)]]
    return [['zstd', '-q', '-dc', str(archive)],
            ['/usr/bin/aa', 'extract', '-d', str(destination), '-exclude-field', 'uid,gid',
             '-no-ignore-eperm', '-afsc-none', '-t', '4', '-wt', '4']]


def measure(mode, command_list):
    started = time.monotonic()
    children = []
    for index, command in enumerate(command_list):
        child = subprocess.Popen(command, stdin=children[-1].stdout if children else None,
                                 stdout=subprocess.PIPE if index < len(command_list) - 1 else None)
        if children:
            children[-1].stdout.close()
        children.append(child)
    usage, codes = [], []
    for child in reversed(children):
        _, status, resource = os.wait4(child.pid, 0)
        child.returncode = os.waitstatus_to_exitcode(status)
        codes.append(child.returncode)
        usage.append(resource)
    row = {'mode': mode, 'wall_seconds': time.monotonic() - started,
           'user_seconds': sum(value.ru_utime for value in usage),
           'system_seconds': sum(value.ru_stime for value in usage), 'exit_codes': codes}
    print(json.dumps(row), flush=True)
    assert all(code == 0 for code in codes), row
    return row


def prepare(args):
    assert digest(args.archive) == args.sha256
    temporary = Path(tempfile.mkdtemp(prefix='parallel-extract-prepare-'))
    try:
        source = temporary / 'source'
        source.mkdir()
        measure('prepare-original', commands('tar', args.archive, source))
        expected = inventory(source)
        args.output.mkdir(parents=True, exist_ok=True)
        target = args.output / 'base.aar.zst'
        measure('prepare-aa-zstd', [
            ['/usr/bin/aa', 'archive', '-d', str(source), '-a', 'raw', '-t', '4'],
            ['zstd', '--ultra', '-19', '--long=27', '-T4', '-q', '-o', str(target)]])
        shutil.copyfile(args.archive, args.output / 'base.tar.zst')
        archives = {mode: {'name': name, 'bytes': (args.output / name).stat().st_size,
                           'sha256': digest(args.output / name)}
                    for mode, name in [('tar', 'base.tar.zst'), ('aa', 'base.aar.zst')]}
        (args.output / 'manifest.json').write_text(json.dumps({'archives': archives, 'expected': expected}) + '\n')
    finally:
        shutil.rmtree(temporary)
        assert not temporary.exists()


def compare(args):
    manifest = json.loads((args.input / 'manifest.json').read_text())
    assert manifest['archives']['tar']['sha256'] == args.sha256
    for archive in manifest['archives'].values():
        file = args.input / archive['name']
        assert file.stat().st_size == archive['bytes'] and digest(file) == archive['sha256']
    temporary = Path(tempfile.mkdtemp(prefix='.php-darwin-parallel-profile-', dir=args.prefix))
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'order': args.order, 'archives': manifest['archives'], 'results': []}
    try:
        with (args.output / 'environment.txt').open('w') as output:
            for command in [['sw_vers'], ['sysctl', 'hw.memsize', 'hw.ncpu'], ['vm_stat']]:
                subprocess.run(command, stdout=output, stderr=output, check=True)
        order = ['tar', 'aa', 'aa', 'tar'] if args.order == 'tar-first' else ['aa', 'tar', 'tar', 'aa']
        for index, mode in enumerate(order):
            destination = temporary / str(index)
            destination.mkdir()
            row = measure(mode, commands(mode, args.input / manifest['archives'][mode]['name'], destination))
            actual = inventory(destination)
            assert actual == manifest['expected'], 'Content, modes, flags, xattrs, symlinks or hardlinks changed'
            row.update(position=index, members=len(actual['files']), all_metadata_equal=True)
            report['results'].append(row)
            shutil.rmtree(destination)
    finally:
        shutil.rmtree(temporary)
        report['temporary_removed'] = not temporary.exists()
        (args.output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['prepare', 'compare'])
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prefix', type=Path)
    parser.add_argument('--order', choices=['tar-first', 'aa-first'])
    options = parser.parse_args()
    prepare(options) if options.mode == 'prepare' else compare(options)
