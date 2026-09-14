import json
import os
import pathlib
import subprocess
import tempfile
import time
from bench_network import run, sha

arch = 'arm64' if run('uname', '-m').strip() == 'arm64' else 'x86_64'
results = []
for version in ['5.6', '7.4', '8.6']:
    manifest = json.loads(run('curl', '-fsSL', '--retry', '3', f'https://artifacts.php-darwin.setup-php.com/php-{version}/php-{version}-manifest.json'))
    asset = next(a for a in manifest['assets'] if a['architecture'] == arch and a['build'] == 'release' and a['thread_safety'] == 'nts')
    archive = pathlib.Path('payload.tar.zst').resolve()
    run('curl', '-fsSL', '--retry', '3', f'https://artifacts.php-darwin.setup-php.com/php-{version}/{asset["download"]}', '-o', str(archive))
    assert sha(archive) == asset['sha256']
    for repeat in range(3):
        for mode in (['native', 'pipe'] if repeat % 2 == 0 else ['pipe', 'native']):
            with tempfile.TemporaryDirectory(prefix='php-darwin-decoder-') as directory:
                args = ['tar', '--ignore-zeros', '-xkmpf', str(archive) if mode == 'native' else '-', '--no-same-owner', '-C', directory]
                started = time.monotonic()
                if mode == 'native':
                    run(*args)
                else:
                    with subprocess.Popen(['zstd', '-qdc', str(archive)], stdout=subprocess.PIPE) as decoder:
                        subprocess.run(args, stdin=decoder.stdout, check=True)
                        decoder.stdout.close()
                        assert decoder.wait() == 0
                elapsed = time.monotonic() - started
                assert any(pathlib.Path(directory).glob('Cellar/php*/**/bin/php'))
                row = {'os': os.environ['RUNNER_LABEL'], 'php': version, 'mode': mode, 'repeat': repeat, 'elapsed_seconds': elapsed, 'sha256': asset['sha256']}
                results.append(row)
                print(json.dumps(row), flush=True)
                pathlib.Path('decoder-results.json').write_text(json.dumps(results, indent=2) + '\n')
    archive.unlink()
