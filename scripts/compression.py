import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time


def sha(path):
    with open(path, 'rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
        return digest.hexdigest()


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout


def prepare():
    version, arch = os.environ['PHP_VERSION'], os.environ['ARCH']
    manifest = json.loads(run('curl', '-fsSL', '--retry', '3', f'https://artifacts.php-darwin.setup-php.com/php-{version}/php-{version}-manifest.json'))
    asset = next(a for a in manifest['assets'] if a['architecture'] == arch and a['build'] == 'release' and a['thread_safety'] == 'nts')
    print(json.dumps(asset), flush=True)
    original = pathlib.Path('level19.tar.zst')
    run('curl', '-fsSL', '--retry', '3', f'https://github.com/shivammathur/php-darwin/releases/download/php-{version}/{asset["download"]}', '-o', str(original))
    assert sha(original) == asset['sha256']
    run('zstd', '-qd', str(original), '-o', 'payload.tar')
    payload_sha = sha('payload.tar')
    # Inventory actual payload bytes, including files from concatenated tar streams.
    inventory = {}
    with tarfile.open('payload.tar', ignore_zeros=True) as archive:
        for member in archive:
            if not member.isfile():
                continue
            parts = member.name.split('/')
            group = '/'.join(parts[:2]) if parts[0] == 'Cellar' else parts[0]
            row = inventory.setdefault(group, {'files': 0, 'bytes': 0})
            row['files'] += 1
            row['bytes'] += member.size
    run('zstd', '--ultra', '-22', '--long=27', '-T2', '-q', 'payload.tar', '-o', 'level22.tar.zst')
    run('zstd', '-qd', 'level22.tar.zst', '-o', 'verify.tar')
    assert sha('verify.tar') == payload_sha
    samples = []
    for level in [19, 22]:
        target = f'php-{version}-{arch}-level-{level}.tar.zst'
        shutil.move(f'level{level}.tar.zst', target)
        samples.append({'level': level, 'name': target, 'sha256': sha(target), 'bytes': pathlib.Path(target).stat().st_size})
        run('gh', 'release', 'upload', os.environ['BENCH_TAG'], target, '--repo', os.environ['GITHUB_REPOSITORY'])
    data = {'php': version, 'arch': arch, 'source': asset, 'payload_sha256': payload_sha, 'inventory': inventory, 'samples': samples}
    metadata = f'php-{version}-{arch}-samples.json'
    pathlib.Path(metadata).write_text(json.dumps(data, indent=2) + '\n')
    run('gh', 'release', 'upload', os.environ['BENCH_TAG'], metadata, '--repo', os.environ['GITHUB_REPOSITORY'])
    print(json.dumps(data), flush=True)


def measure():
    arch = 'arm64' if run('uname', '-m').strip() == 'arm64' else 'x86_64'
    base = f'https://github.com/{os.environ["GITHUB_REPOSITORY"]}/releases/download/{os.environ["BENCH_TAG"]}'
    results = []
    for version in ['7.4', '8.6']:
        data = json.loads(run('curl', '-fsSL', '--retry', '3', f'{base}/php-{version}-{arch}-samples.json'))
        for repeat in range(3):
            samples = data['samples'] if (repeat + int(os.environ['SAMPLE'])) % 2 == 0 else data['samples'][::-1]
            for sample in samples:
                with tempfile.TemporaryDirectory(prefix='php-darwin-wire-') as directory:
                    root = pathlib.Path(directory)
                    archive = root / 'payload.tar.zst'
                    started = time.monotonic()
                    transfer = json.loads(run('curl', '-fsSL', '--retry', '0', '--connect-timeout', '2', '--max-time', '30', '-w', '%{json}', f'{base}/{sample["name"]}', '-o', str(archive)))
                    downloaded = time.monotonic()
                    assert sha(archive) == sample['sha256']
                    verified = time.monotonic()
                    destination = root / 'prefix'
                    destination.mkdir()
                    run('tar', '--ignore-zeros', '-xmpf', str(archive), '--no-same-owner', '-C', str(destination))
                    extracted = time.monotonic()
                    assert any(destination.glob('Cellar/php*/**/bin/php'))
                    row = {'os': os.environ['RUNNER_LABEL'], 'php': version, 'repeat': repeat, 'level': sample['level'], 'bytes': sample['bytes'],
                           'download_seconds': downloaded-started, 'sha256_seconds': verified-downloaded, 'extract_seconds': extracted-verified,
                           'total_seconds': extracted-started, 'curl': {key: transfer[key] for key in ['time_namelookup', 'time_connect', 'time_appconnect', 'time_starttransfer', 'time_total', 'num_redirects', 'speed_download']}}
                    results.append(row)
                    print(json.dumps(row), flush=True)
                    pathlib.Path('compression-results.json').write_text(json.dumps(results, indent=2) + '\n')


prepare() if sys.argv[1] == 'prepare' else measure()
