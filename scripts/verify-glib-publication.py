"""Verify public package contents against the accepted CI artifact manifests."""
import concurrent.futures
import hashlib
import io
import json
import subprocess
import threading
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / 'publication-manifest.json').read_text())
OUT = ROOT / 'publication-results'
OUT.mkdir(exist_ok=True)
RESPONSES = []
RESPONSE_LOCK = threading.Lock()


def fetch(url):
    request = urllib.request.Request(url, headers={'Cache-Control': 'no-cache'})
    with urllib.request.urlopen(request, timeout=90) as response:
        data = response.read()
        with RESPONSE_LOCK:
            RESPONSES.append({'url': url, 'headers': dict(response.headers)})
            (OUT / 'responses.json').write_text(json.dumps(RESPONSES, indent=2) + '\n')
        return data


def archive(package):
    library, lane, arch = (package[key] for key in ['library', 'lane', 'arch'])
    vs = MANIFEST['lanes'][lane]
    category = f'php-sdk/deps/{vs}/{arch}' if library in ['glib', 'enchant'] else 'pecl/deps'
    url = f'https://downloads.php.net/~windows/{category}/{package["name"]}.zip'
    data = fetch(url)
    with zipfile.ZipFile(io.BytesIO(data)) as source:
        assert source.testzip() is None
        files = {name: hashlib.sha256(source.read(name)).hexdigest()
                 for name in source.namelist() if not name.endswith('/')}
    assert files == package['files'], (url, 'published contents differ')
    print(package['name'], 'verified', flush=True)
    return {'url': url, 'library': library, 'lane': lane, 'arch': arch,
            'sha256': hashlib.sha256(data).hexdigest(), 'files': len(files)}


def indexes():
    checked = []
    mismatches = []
    for lane, vs in MANIFEST['lanes'].items():
        for php in MANIFEST['targets'][lane].split(','):
            for stability in (['stable', 'staging'] if php in ['8.6', '8.7', 'master'] else ['staging']):
                for arch in ['x86', 'x64']:
                    url = f'https://downloads.php.net/~windows/php-sdk/deps/series/packages-{php}-{vs}-{arch}-{stability}.txt'
                    lines = fetch(url).decode().splitlines()
                    for library in ['glib', 'enchant']:
                        name = MANIFEST['names'].get(library, library)
                        expected = f'{name}-{MANIFEST["versions"][library]}-{vs}-{arch}.zip'
                        selected = [line for line in lines if line.startswith(name + '-')]
                        if selected != [expected]:
                            mismatches.append({'url': url, 'expected': expected, 'actual': selected})
                    checked.append(url)
    lines = fetch('https://downloads.php.net/~windows/pecl/deps/packages.txt').decode().splitlines()
    for package in MANIFEST['packages']:
        if package['library'] in ['pango', 'librrd']:
            if lines.count(package['name'] + '.zip') != 1:
                mismatches.append({'pecl_package': package['name'], 'matches': lines.count(package['name'] + '.zip')})
    (OUT / 'index-verification.json').write_text(json.dumps({'series': checked, 'mismatches': mismatches}, indent=2) + '\n')
    return checked, mismatches


def install(item):
    lane, vs, arch = item
    directory = OUT / f'fetch-{lane}-{arch}'
    directory.mkdir()
    command = ['pwsh', '-NoLogo', '-NoProfile', '-File', str(ROOT / 'publication-builder/scripts/fetch-deps.ps1'),
               '-lib', 'librrd', '-version', lane, '-vs', vs, '-arch', arch, '-stability', 'staging']
    result = subprocess.run(command, cwd=directory, capture_output=True, text=True)
    (directory / 'fetch.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (lane, arch, result.stderr)
    checked = {}
    for library in ['glib', 'pango']:
        package = next(p for p in MANIFEST['packages']
                       if (p['library'], p['lane'], p['arch']) == (library, lane, arch))
        assert package['name'] + '.zip' in result.stdout
        count = 0
        for name, digest in package['files'].items():
            # Shared root README/license files are checked in the individual ZIPs.
            if '/' not in name:
                continue
            path = directory / 'deps' / name
            with path.open('rb') as source:
                assert hashlib.file_digest(source, 'sha256').hexdigest() == digest, path
            count += 1
        checked[library] = {'artifact': package['name'], 'files': count}
    print(lane, arch, 'fetch-deps verified', flush=True)
    return {'lane': lane, 'arch': arch, 'verified': checked}


def main():
    commit = subprocess.check_output(['git', '-C', str(ROOT / 'publication-builder'), 'rev-parse', 'HEAD'], text=True).strip()
    assert commit == MANIFEST['builder_commit']
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        archives = list(pool.map(archive, MANIFEST['packages']))
    (OUT / 'archive-verification.json').write_text(json.dumps(archives, indent=2) + '\n')
    tasks = [(lane, vs, arch) for lane, vs in MANIFEST['lanes'].items() for arch in ['x86', 'x64']]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        index_task = pool.submit(indexes)
        resolved = list(pool.map(install, tasks))
        series, mismatches = index_task.result()
    (OUT / 'published-fetch-deps-verification.json').write_text(json.dumps(resolved, indent=2) + '\n')
    assert not mismatches, mismatches
    (OUT / 'publication-verification.json').write_text(json.dumps(
        {'artifacts': archives, 'series': series, 'pecl_index': 'verified'}, indent=2) + '\n')
    print('Verified 24 public archives, 20 series files, PECL index, and 6 fresh fetch-deps installations.')


try:
    main()
except Exception as error:
    (OUT / 'failure.json').write_text(json.dumps({'error': str(error), 'type': type(error).__name__}, indent=2) + '\n')
    raise
