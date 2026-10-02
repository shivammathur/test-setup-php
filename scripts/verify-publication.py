"""Check actual consumer URLs from a Windows build runner; no cache bypass."""
import concurrent.futures
import datetime
import email.utils
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request

tasks = json.loads(Path('publication-matrix.json').read_text())
assert len(tasks) == 53
destination = Path('publication-reports')
destination.mkdir(exist_ok=True)

def check(task):
    result = dict(task, observed=datetime.datetime.now(datetime.timezone.utc).isoformat(), passed=False)
    try:
        request = urllib.request.Request(task['url'], headers={'User-Agent': 'Winlibs-release-validation'})
        with urllib.request.urlopen(request, timeout=120) as response:
            result['headers'] = dict(response.headers)
            data = response.read()
        result['sha256'] = hashlib.sha256(data).hexdigest()
        if task['kind'] == 'zip':
            modified = email.utils.parsedate_to_datetime(result['headers']['Last-Modified'])
            assert modified >= datetime.datetime.fromisoformat(task['uploaded']), 'Package predates upload'
            result['passed'] = result['sha256'] == task['expected']
        else:
            (destination / task['name']).write_bytes(data)
            lines = data.decode().splitlines()
            if task['kind'] == 'series':
                result['selected'] = [line for line in lines if line.startswith('libpng-')]
                result['passed'] = result['selected'] == [task['expected']]
                result['other_changes'] = {
                    'removed': sorted(set(task['original'])-set(lines)-{x for x in task['original'] if x.startswith('libpng-')}),
                    'added': sorted(set(lines)-set(task['original'])-set(result['selected'])),
                }
            else:
                result['missing'] = sorted(set(task['expected'])-set(lines))
                result['passed'] = not result['missing']
    except Exception as error:
        result['error'] = str(error)
        if isinstance(error, urllib.error.HTTPError): result['headers'] = dict(error.headers)
    print(task['name'], 'PASS' if result['passed'] else 'FAIL', result.get('error', ''), flush=True)
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(check, tasks))
report = {'observed': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'location': 'GitHub Windows 2022 hosted runner',
          'passed': all(r['passed'] for r in results), 'results': results}
(destination / 'verification.json').write_text(json.dumps(report, indent=2)+'\n')
raise SystemExit(0 if report['passed'] else 1)
