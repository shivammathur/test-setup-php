import hashlib
import json
import os
import pathlib
import resource
import stat
import subprocess
import tarfile
import tempfile
import time


def sha(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


def fetch(url, output):
    subprocess.run(['curl', '-fsSL', '--retry', '0', '--connect-timeout', '10',
                    '--max-time', '60', url, '-o', str(output)], check=True)


version = os.environ['PHP_VERSION']
first = os.environ['FIRST']
assert version in ('8.3', '8.5') and first in ('tar', 'pax')
expected = json.loads(pathlib.Path('assets.json').read_text())[version]
result = {'php': version, 'runner': os.environ.get('RUNNER_NAME'),
          'os': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
          'tar': subprocess.check_output(['tar', '--version'], text=True).strip(), 'samples': []}
with tempfile.TemporaryDirectory(prefix='php-darwin-extract-') as folder:
    root = pathlib.Path(folder)
    archive = root / 'cache.tar.zst'
    base = f'https://artifacts.php-darwin.setup-php.com/php-{version}'
    fetch(f'{base}/{expected["download"]}', archive)
    assert sha(archive) == expected['sha256']
    result['archive'] = expected
    for mode in [first, 'pax' if first == 'tar' else 'tar']:
        destination = root / mode
        destination.mkdir()
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        started = time.monotonic()
        if mode == 'tar':
            subprocess.run(['tar', '--ignore-zeros', '-xkmpf', str(archive), '--no-same-owner',
                            '--numeric-owner', '-C', str(destination)], check=True)
        else:
            with subprocess.Popen(['zstd', '-qdc', str(archive)], stdout=subprocess.PIPE) as decoder:
                subprocess.run(['/bin/pax', '-r', '-k', '-p', 'pm'], cwd=destination,
                               stdin=decoder.stdout, check=True)
                decoder.stdout.close()
                assert decoder.wait() == 0
        elapsed = time.monotonic() - started
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        sample = {'mode': mode, 'first': mode == first, 'seconds': elapsed,
                  'user_seconds': after.ru_utime - usage.ru_utime,
                  'system_seconds': after.ru_stime - usage.ru_stime}
        result['samples'].append(sample)
        pathlib.Path('results.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(sample), flush=True)
    # Verify after both timed extractions, to avoid warming file contents
    # asymmetrically. Read every expected regular file and exact symlink target.
    counts = {'files': 0, 'symlinks': 0, 'bytes': 0}
    with subprocess.Popen(['zstd', '-qdc', str(archive)], stdout=subprocess.PIPE) as decoder:
        with tarfile.open(fileobj=decoder.stdout, mode='r|', ignore_zeros=True) as contents:
            for member in contents:
                assert not member.name.startswith('/') and '..' not in member.name.split('/')
                paths = [root / mode / member.name for mode in ('tar', 'pax')]
                if member.isfile():
                    digest = hashlib.sha256()
                    source = contents.extractfile(member)
                    for block in iter(lambda: source.read(1024 * 1024), b''):
                        digest.update(block)
                    for path in paths:
                        info = path.lstat()
                        assert stat.S_ISREG(info.st_mode) and info.st_size == member.size, member.name
                        assert stat.S_IMODE(info.st_mode) == member.mode & 0o7777, member.name
                        assert sha(path) == digest.hexdigest(), member.name
                    counts['files'] += 1
                    counts['bytes'] += member.size
                elif member.issym():
                    for path in paths:
                        assert path.is_symlink() and os.readlink(path) == member.linkname, member.name
                    counts['symlinks'] += 1
                else:
                    assert member.isdir(), (member.name, member.type)
        decoder.stdout.close()
        assert decoder.wait() == 0
    assert counts['files'] > 1000 and counts['symlinks'] > 100
    result['verified'] = counts
    pathlib.Path('results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
