import concurrent.futures
import datetime
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request

manifest = json.loads(Path('publication-manifest.json').read_text())
destination = Path('reports')
destination.mkdir(exist_ok=True)

def verify(item):
    result = dict(item)
    result['observedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result['verified'] = False
    try:
        with urllib.request.urlopen(item['url'], timeout=180) as response:
            result['headers'] = dict(response.headers)
            result['status'] = response.status
            data = response.read()
        digest = hashlib.sha256(data).hexdigest()
        result['actualSha256'] = digest
        if item['kind'] == 'archive':
            result['verified'] = digest == item['sha256']
        else:
            text = data.decode()
            (destination / item['name']).write_text(text)
            if item['kind'] == 'unchanged':
                result['verified'] = digest == item['sha256']
            elif item['kind'] == 'series':
                actual = text.splitlines()
                result['verified'] = all(
                    [line for line in actual if line.startswith(library + '-')] == [package]
                    for library, package in item['packages'].items()
                )
            elif item['kind'] == 'package-index':
                result['verified'] = set(item['packages']) <= set(text.splitlines())
            elif item['kind'] == 'directory-index':
                result['verified'] = all(package in text for package in item['packages'])
            elif item['kind'] == 'mapping':
                result['parsed'] = json.loads(text)
                result['verified'] = True
    except urllib.error.HTTPError as error:
        result.update(status=error.code, headers=dict(error.headers), error=str(error))
    except Exception as error:
        result['error'] = str(error)
    print(json.dumps({key: result[key] for key in ('url', 'verified')}), flush=True)
    return result

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    results = list(executor.map(verify, manifest['items']))
(destination / 'publication-results.json').write_text(json.dumps(results, indent=2) + '\n')
if not all(result['verified'] for result in results):
    raise SystemExit('Canonical publication does not yet match the approved release manifest')
