"""Verify standard consumer URLs against exact accepted GitHub artifact digests."""
import concurrent.futures
import datetime
import email.utils
import hashlib
import io
import json
from pathlib import Path
import re
import urllib.error
import urllib.request
import zipfile

root = Path(__file__).resolve().parent
state = json.loads((root / 'state.json').read_text())
artifact_trees = {x['artifact']: x for x in json.loads((root / 'artifact-inventory.json').read_text())}
public = root / 'public'
public.mkdir(exist_ok=True)
base = 'https://downloads.php.net/~windows/php-sdk/deps/'
observation = datetime.datetime.now(datetime.timezone.utc).isoformat()


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read(), {k.lower(): v for k,v in response.headers.items()}


def changed_timestamp(headers, previous=None):
    reported=email.utils.parsedate_to_datetime(headers['last-modified'])
    dispatched=datetime.datetime.fromisoformat(state['upload_dispatched_at'])
    return reported >= dispatched-datetime.timedelta(minutes=2) and (not previous or reported > email.utils.parsedate_to_datetime(previous))


def package(artifact):
    name = artifact['name']
    _, vs, arch = name.rsplit('-', 2)
    url = f'{base}{vs}/{arch}/{name}.zip'
    row = {'url': url, 'artifact_id': artifact['id'], 'expected_sha256': artifact['digest'].removeprefix('sha256:')}
    try:
        data, headers = fetch(url)
        row.update(sha256=hashlib.sha256(data).hexdigest(), headers=headers)
        (public / (name + '.zip')).write_bytes(data)
        row['digest_matches'] = row['sha256'] == row['expected_sha256']
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            row['bad_zip_member'] = archive.testzip()
            actual = {n: hashlib.sha256(archive.read(n)).hexdigest() for n in archive.namelist() if not n.endswith('/')}
        row['files_match'] = actual == artifact_trees[name]['hashes']
        row['timestamp_fresh'] = changed_timestamp(headers)
        row['passed'] = row['digest_matches'] and row['files_match'] and row['bad_zip_member'] is None and row['timestamp_fresh']
    except Exception as error:
        row.update(passed=False, error=str(error))
        if isinstance(error, urllib.error.HTTPError):
            row['headers'] = {k.lower(): v for k,v in error.headers.items()}
    return row


before = {}
for filename in ['inventory-before.json', 'inventory-aliases-before.json']:
    for entry in json.loads((root / filename).read_text())['series']:
        before[entry['file']] = entry


def series(entry):
    row = {'url': entry['url'], 'file': entry['file'], 'previous_last_modified': entry['lastModified']}
    try:
        data, headers = fetch(entry['url'])
        (public / entry['file']).write_bytes(data)
        packages = data.decode().splitlines()
        match = re.fullmatch(r'packages-(.*?)-(vs\d+)-(x86|x64|arm64)-(stable|staging)\.txt', entry['file'])
        php, vs, arch, stability = match.groups()
        updated = stability == 'staging' or php in ['8.6', '8.7', 'master']
        target_php = 'master' if php == '8.7' else php
        curl = next(x for x in state['lanes'] if target_php in x['php'])
        expected_targets = [f"{curl['tag']}-{vs}-{arch}.zip", f'freetype-2.15.0-{vs}-{arch}.zip'] if updated else [p for p in entry['packages'] if re.match(r'^(libcurl|freetype)-\d', p)]
        actual_targets = [p for p in packages if re.match(r'^(libcurl|freetype)-\d', p)]
        other_before = {p for p in entry['packages'] if not re.match(r'^(libcurl|freetype)-\d', p)}
        other_after = {p for p in packages if not re.match(r'^(libcurl|freetype)-\d', p)}
        row.update(headers=headers, sha256=hashlib.sha256(data).hexdigest(), expected=sorted(expected_targets), actual=sorted(actual_targets),
                   other_added=sorted(other_after-other_before), other_removed=sorted(other_before-other_after),
                   passed=sorted(expected_targets)==sorted(actual_targets))
        row['timestamp_fresh'] = changed_timestamp(headers, entry['lastModified']) if updated else headers.get('last-modified')==entry['lastModified']
        row['passed'] = row['passed'] and row['timestamp_fresh']
    except Exception as error:
        row.update(passed=False, error=str(error))
        if isinstance(error, urllib.error.HTTPError):
            row['headers'] = {k.lower(): v for k,v in error.headers.items()}
    return row


artifacts = []
for dispatch in state['dependency_dispatches']:
    artifacts += json.loads((root / f"logs/artifacts-{dispatch['run']['databaseId']}.json").read_text())['artifacts']
with concurrent.futures.ThreadPoolExecutor(8) as pool:
    packages = list(pool.map(package, artifacts))
    listings = list(pool.map(series, before.values()))
indexes = []
for vs in ['vs16', 'vs17', 'vs18']:
    for arch in ['x86', 'x64', 'arm64']:
        url = f'{base}{vs}/{arch}/'
        data, headers = fetch(url)
        (public / f'index-{vs}-{arch}.html').write_bytes(data)
        lines = [line for line in data.decode().splitlines() if 'freetype-2.15.0-' in line or 'libcurl-8.23.0' in line]
        expected_names=[a['name']+'.zip' for a in artifacts if a['name'].endswith(f'-{vs}-{arch}')]
        present=all(any(name in line for line in lines) for name in expected_names)
        indexes.append({'url': url, 'headers': headers, 'listing_rows': lines, 'expected':expected_names, 'passed':present})
report = {'observed_at': observation, 'packages': packages, 'series': listings, 'directory_indexes': indexes}
(root / 'publication-verification.json').write_text(json.dumps(report, indent=2) + '\n')
history=public/'verification-history';history.mkdir(exist_ok=True)
(history/(observation.replace(':','-')+'.json')).write_text(json.dumps(report,indent=2)+'\n')
failed = [x for x in packages+listings+indexes if not x['passed']]
print(json.dumps({'packages': len(packages), 'series': len(listings), 'indexes': len(indexes), 'passed': len(packages)+len(listings)+len(indexes)-len(failed), 'failures': failed}, indent=2))
raise SystemExit(bool(failed))
