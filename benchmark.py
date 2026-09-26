import hashlib, json, os, pathlib, random, shutil, subprocess, sys, time

arch, repo, tag = (os.environ[key] for key in ('ARCH', 'REPO', 'TAG'))
levels = [10, 15, 17, 19]
root = pathlib.Path(os.environ.get('RUNNER_TEMP', '/tmp')) / ('compression-' + arch)
root.mkdir(exist_ok=True)

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def sha(file):
    with open(file, 'rb') as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
        return value.hexdigest()

def download(url, file):
    started = time.monotonic()
    run('curl', '-fLsS', '--retry', '2', '--max-time', '180', '-o', str(file), url)
    return time.monotonic() - started

if sys.argv[1] == 'prepare':
    manifest = root / 'manifest.json'
    download('https://github.com/shivammathur/php-darwin/releases/download/php-8.5/php-8.5-manifest.json', manifest)
    entry = next(item for item in json.loads(manifest.read_text())['assets'] if item['architecture'] == arch and item['build'] == 'release' and item['thread_safety'] == 'nts')
    original = root / 'original.tar.zst'
    download('https://github.com/shivammathur/php-darwin/releases/download/php-8.5/' + entry.get('download', entry['name']), original)
    assert sha(original) == entry['sha256']
    tar = root / 'payload.tar'
    run('zstd', '-dq', str(original), '-o', str(tar))
    records = []
    for level in levels:
        archive = root / f'php85-{arch}-level{level}.tar.zst'
        run('zstd', '--ultra', f'-{level}', '--long=27', '-T2', '-q', str(tar), '-o', str(archive))
        records.append({'level': level, 'file': archive.name, 'sha256': sha(archive), 'bytes': archive.stat().st_size})
    index = root / f'index-{arch}.json'
    index.write_text(json.dumps({'original': entry, 'tar_sha256': sha(tar), 'records': records}))
    run('gh', 'release', 'upload', tag, '--repo', repo, str(index), *(str(root / item['file']) for item in records))
else:
    base = f'https://github.com/{repo}/releases/download/{tag}/'
    index = root / 'index.json'
    download(base + f'index-{arch}.json', index)
    inputs = json.loads(index.read_text())
    results = []
    for iteration in range(5):
        order = inputs['records'].copy()
        random.Random(20260927 + iteration).shuffle(order)
        for item in order:
            archive = root / item['file']
            elapsed_download = download(base + item['file'], archive)
            started = time.monotonic()
            assert sha(archive) == item['sha256']
            elapsed_verify = time.monotonic() - started
            destination = root / 'extracted'
            destination.mkdir()
            started = time.monotonic()
            decompress = subprocess.Popen(['zstd', '-dcq', str(archive)], stdout=subprocess.PIPE)
            extracted = subprocess.run(['tar', '-xf', '-', '-C', str(destination)], stdin=decompress.stdout)
            decompress.stdout.close()
            assert extracted.returncode == 0 and decompress.wait() == 0
            elapsed_extract = time.monotonic() - started
            record = dict(item, iteration=iteration, download=elapsed_download, verify=elapsed_verify,
                          extract=elapsed_extract, total=elapsed_download + elapsed_verify + elapsed_extract)
            results.append(record)
            print(json.dumps(record), flush=True)
            pathlib.Path(f'results-{arch}.json').write_text(json.dumps(results, indent=2))
            shutil.rmtree(destination)
            archive.unlink()
