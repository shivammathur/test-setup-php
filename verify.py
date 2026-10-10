import concurrent.futures
import json
import os
from pathlib import Path
import platform
import re
import socket
import subprocess
import sys
import tempfile
import time


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=120, **kwargs).strip()


phase = sys.argv[1]
version = os.environ['PHP_VERSION']
arch = platform.machine()
prefix = Path(run('brew', '--prefix'))
evidence = Path('evidence')
evidence.mkdir(exist_ok=True)
manifest = json.loads(run('curl', '-fsSL', '--retry', '3', '--max-time', '60',
    f'https://artifacts.php-darwin.setup-php.com/php-{version}/php-{version}-manifest.json'))
tap = run('brew', '--repository', 'shivammathur/php')
snapshot = run('git', '-C', tap, 'config', '--get', 'php-darwin.snapshot-commit')
assert snapshot == manifest['homebrew_php_commit'] == run('git', '-C', tap, 'rev-parse', 'HEAD')
expected_version = manifest['php_semver'] + ('-dev' if version in ['8.6', '8.7'] else '')
assert run('php-config', '--version') == expected_version
assert run('php', '-r', 'echo PHP_DEBUG, ":", PHP_ZTS;') == '0:0'
php_root = Path(run('php', '-r', 'echo PHP_BINARY;')).resolve(strict=True).parent.parent
receipt = json.loads((php_root / 'INSTALL_RECEIPT.json').read_text())
(evidence / f'{phase}-cache.json').write_text(json.dumps({'manifest': manifest, 'receipt': receipt, 'snapshot': snapshot}, indent=2))
roots = [php_root]
for package in receipt['runtime_dependencies']:
    name = package['full_name'].split('/')[-1]
    assert name != 'openssl@3', package
    roots.append((prefix / 'opt' / name).resolve(strict=True))
assert any(p.parent.name == 'openssl@4' for p in roots), roots
extension_dir = Path(run('php-config', '--extension-dir'))
modules = ['imagick', 'mongodb', 'memcached', 'igbinary', 'msgpack']
if tuple(map(int, version.split('.'))) < (8, 6):
    modules.append('swoole')
pack_roots = set()
for module in modules:
    link = extension_dir / f'{module}.so'
    assert link.is_symlink(), f'{module} was not installed from its pack'
    target = link.resolve(strict=True)
    assert str(target).startswith(str(prefix / 'var/php-darwin/extensions') + '/'), target
    pack_roots.add(target.parent.parent)
for root in pack_roots:
    pack = json.loads((root / 'metadata.json').read_text())
    assert pack['php_version'] == version and pack['build'] == 'release' and pack['thread_safety'] == 'nts'
    assert not any(d['name'] == 'openssl@3' for d in pack['dependencies']), pack['name']
    (evidence / f"{phase}-{pack['name']}.json").write_text(json.dumps(pack, indent=2))
roots.extend(pack_roots)
magic = {bytes.fromhex(s) for s in ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
binaries = set()
for root in roots:
    for directory, _, files in os.walk(root):
        for name in files:
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            with path.open('rb') as source:
                if source.read(4) in magic:
                    binaries.add(path)


def linkage(binary):
    links = run('otool', '-L', str(binary))
    assert not re.search(r'lib(?:ssl|crypto)\.(?:[0-35-9])[^/]*\.dylib|openssl@3', links), (str(binary), links)
    return {'file': str(binary), 'links': links.splitlines()[1:]}


with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    links = list(pool.map(linkage, sorted(binaries)))
assert links and any('libssl.4.dylib' in str(item) for item in links)
(evidence / f'{phase}-linkage.json').write_text(json.dumps(links, indent=2))
started = int((Path(os.environ['RUNNER_TEMP']) / 'install-started.txt').read_text())
installed = json.loads(run('brew', 'info', '--installed', '--json=v2'))
source_builds = [f['name'] for f in installed['formulae'] for receipt in f['installed']
                 if receipt.get('time', 0) >= started and receipt.get('poured_from_bottle') is not True]
assert not source_builds, f'Unexpected source builds: {source_builds}'
with tempfile.TemporaryDirectory() as temporary:
    ca = Path(temporary) / 'cert.pem'
    key = Path(temporary) / 'key.pem'
    openssl = prefix / 'opt/openssl@4/bin/openssl'
    run(str(openssl), 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(ca),
        '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost', stderr=subprocess.DEVNULL)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    server = subprocess.Popen([str(openssl), 's_server', '-accept', f'127.0.0.1:{port}', '-cert', str(ca), '-key', str(key), '-www'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                    break
            except OSError:
                assert server.poll() is None, 'TLS server exited'
                time.sleep(0.1)
        result = subprocess.run(['php', 'smoke.php'], text=True, capture_output=True, timeout=120,
                                env={**os.environ, 'TLS_URL': f'https://localhost:{port}/', 'TLS_CA': str(ca)})
        (evidence / f'{phase}-smoke.txt').write_text(result.stdout + result.stderr)
        assert result.returncode == 0 and not result.stderr, result.stdout + result.stderr
        print(result.stdout)
    finally:
        server.terminate()
        server.wait(timeout=10)
report = {'php': version, 'arch': arch, 'phase': phase, 'mach_o_files': len(links),
          'optional_modules': modules, 'source_builds': source_builds, 'openssl': '4', 'smoke': 'passed'}
(evidence / f'{phase}-summary.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
