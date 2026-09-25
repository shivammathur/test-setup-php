import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
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
    result = {}
    for file in sorted(root.rglob('*')):
        details = file.lstat()
        entry = {'type': stat.S_IFMT(details.st_mode), 'mode': stat.S_IMODE(details.st_mode)}
        if file.is_symlink():
            entry['target'] = os.readlink(file)
        elif file.is_file():
            entry.update(bytes=details.st_size, sha256=digest(file))
        result[str(file.relative_to(root))] = entry
    return result


def snapshot(output, name):
    with (output / name).open('w') as log:
        for command in [['sw_vers'], ['sysctl', 'hw.memsize', 'hw.ncpu'], ['vm_stat'],
                        ['df', '-h', '/usr/local'], ['iostat', '-Id'], ['/usr/bin/tar', '--version']]:
            log.write('\n' + ' '.join(command) + '\n')
            log.flush()
            subprocess.run(command, stdout=log, stderr=log, check=False, timeout=15)


def extract(archive, output, destination, tracing):
    name = 'traced' if tracing else 'baseline'
    trace = sample = None
    handles = []
    snapshot(output, name + '-before.txt')
    started = time.monotonic()
    proc = subprocess.Popen(['/usr/bin/tar', '--ignore-zeros', '-xkmpf', str(archive),
                             '--no-same-owner', '--numeric-owner', '-C', str(destination)])
    try:
        if tracing:
            # Read-only diagnostics, limited to this tar PID and 15 seconds.
            for filename in ['fs-usage.txt', 'sample-command.txt']:
                handles.append((output / filename).open('w'))
            trace = subprocess.Popen(['sudo', '-n', '/usr/bin/fs_usage', '-w', '-f', 'filesys',
                                      '-t', '15', str(proc.pid)], stdout=handles[0], stderr=handles[0])
            sample = subprocess.Popen(['/usr/bin/sample', str(proc.pid), '10', '1', '-mayDie',
                                       '-file', str(output / 'tar-sample.txt')],
                                      stdout=handles[1], stderr=handles[1])
        _, status, usage = os.wait4(proc.pid, 0)
        proc.returncode = os.waitstatus_to_exitcode(status)
        elapsed = time.monotonic() - started
        result = {'mode': name, 'wall_seconds': elapsed, 'user_seconds': usage.ru_utime,
                  'system_seconds': usage.ru_stime, 'max_rss_bytes': usage.ru_maxrss,
                  'page_faults': usage.ru_majflt, 'minor_faults': usage.ru_minflt,
                  'block_inputs': usage.ru_inblock, 'block_outputs': usage.ru_oublock,
                  'exit_code': proc.returncode}
        assert proc.returncode == 0, result
        snapshot(output, name + '-after.txt')
        return result
    finally:
        for diagnostic in [trace, sample]:
            if diagnostic is None:
                continue
            try:
                diagnostic.wait(timeout=20)
            except subprocess.TimeoutExpired:
                # Stop only the diagnostic launched above, never a service.
                if diagnostic is trace:
                    subprocess.run(['sudo', '-n', 'kill', '-INT', str(diagnostic.pid)], check=False)
                else:
                    diagnostic.send_signal(signal.SIGINT)
                diagnostic.wait(timeout=10)
        for handle in handles:
            handle.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--bytes', type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--trace', action='store_true')
    args = parser.parse_args()
    assert args.archive.stat().st_size == args.bytes and digest(args.archive) == args.sha256
    args.output.mkdir(parents=True, exist_ok=True)
    # No file in the existing Homebrew tree is replaced and no PHP is executed.
    temporary = Path(tempfile.mkdtemp(prefix='.php-darwin-extract-profile-', dir=args.prefix))
    results = []
    try:
        baseline = None
        for tracing in [False, args.trace]:
            destination = temporary / ('traced' if tracing else f'baseline-{len(results)}')
            destination.mkdir()
            result = extract(args.archive, args.output, destination, tracing)
            files = inventory(destination)
            if baseline is None:
                baseline = files
            else:
                assert files == baseline, 'Extracted bytes, modes or links differ'
            result['verified_members'] = len(files)
            results.append(result)
            print(json.dumps(result), flush=True)
            shutil.rmtree(destination)
        (args.output / 'result.json').write_text(json.dumps({
            'archive_sha256': args.sha256, 'archive_bytes': args.bytes,
            'modes_hashes_links_equal': True, 'results': results}, indent=2) + '\n')
    finally:
        shutil.rmtree(temporary)
        assert not temporary.exists()


if __name__ == '__main__':
    main()
