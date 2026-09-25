import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time


def digest(file):
    with file.open('rb') as handle:
        result = hashlib.sha256()
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(block)
        return result.hexdigest()


def inventory(root):
    result, physical, compressed = {}, 0, 0
    for file in sorted(root.rglob('*')):
        details = file.lstat()
        entry = {'type': stat.S_IFMT(details.st_mode), 'mode': stat.S_IMODE(details.st_mode)}
        if file.is_symlink():
            entry['target'] = os.readlink(file)
        elif file.is_file():
            entry.update(bytes=details.st_size, sha256=digest(file))
            physical += details.st_blocks * 512
            compressed += bool(details.st_flags & stat.UF_COMPRESSED)
        result[str(file.relative_to(root))] = entry
    return result, physical, compressed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--bytes', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    args = parser.parse_args()
    assert args.archive.stat().st_size == args.bytes and digest(args.archive) == args.sha256
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / 'environment.txt').open('w') as output:
        for command in [['sw_vers'], ['sysctl', 'hw.memsize', 'hw.ncpu'], ['vm_stat'], ['/usr/bin/tar', '--version']]:
            subprocess.run(command, stdout=output, stderr=output, check=True)
    temporary = Path(tempfile.mkdtemp(prefix='.php-darwin-compression-profile-', dir=args.prefix))
    results = []
    try:
        baseline = None
        baseline_signatures = None
        # ABBA measures both native-first and native-last; no tracing overhead.
        for index, compressed in enumerate([False, True, True, False]):
            destination = temporary / str(index)
            destination.mkdir()
            command = ['/usr/bin/tar', '--ignore-zeros', '-xkmpf', str(args.archive),
                       '--no-same-owner', '--numeric-owner', '-C', str(destination)]
            if compressed:
                command.append('--hfsCompression')
            started = time.monotonic()
            process = subprocess.Popen(command)
            _, status, usage = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
            elapsed = time.monotonic() - started
            assert process.returncode == 0
            files, physical, compressed_files = inventory(destination)
            if baseline is None:
                baseline = files
            else:
                assert files == baseline, 'File contents, modes or links changed'
            signed = []
            for file in destination.glob('Cellar/php*/*/bin/php'):
                if file.is_symlink():
                    continue
                check = subprocess.run(['/usr/bin/codesign', '--verify', '--verbose=2', str(file)],
                                       text=True, capture_output=True)
                signed.append({'path': str(file.relative_to(destination)), 'exit_code': check.returncode,
                               'output': check.stderr.replace(str(destination), '$ROOT')})
            if baseline_signatures is None:
                baseline_signatures = signed
            else:
                assert signed == baseline_signatures, 'Code signature verification changed'
            result = {'position': index, 'mode': 'compressed' if compressed else 'native',
                      'wall_seconds': elapsed, 'user_seconds': usage.ru_utime,
                      'system_seconds': usage.ru_stime, 'physical_bytes': physical,
                      'compressed_files': compressed_files, 'members': len(files), 'signatures': signed}
            results.append(result)
            print(json.dumps(result), flush=True)
            (args.output / 'result.json').write_text(json.dumps({
                'archive_sha256': args.sha256, 'archive_bytes': args.bytes,
                'modes_hashes_links_equal': True, 'results': results}, indent=2) + '\n')
            shutil.rmtree(destination)
    finally:
        shutil.rmtree(temporary)
        assert not temporary.exists()


if __name__ == '__main__':
    main()
