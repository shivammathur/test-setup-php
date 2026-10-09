import concurrent.futures
import datetime
import hashlib
import json
import time
import urllib.request
from pathlib import Path

tasks = json.loads(Path('manifest.json').read_text())
destination = Path('results')
destination.mkdir(exist_ok=True)
accepted = {}

def verify(task):
    try:
        with urllib.request.urlopen(task['url'], timeout=60) as response:
            headers = dict(response.headers.items())
            data = response.read()
            assert response.status == 200
        digest = hashlib.sha256(data).hexdigest()
        if task['type'] == 'archive':
            assert digest == task['sha256'], 'Archive SHA256 mismatch'
        else:
            lines = data.decode().splitlines()
            selected = [line for line in lines if line.startswith('libzip-')]
            assert len(selected) == 1 and selected[0] in task['allowed'], selected
            assert [line for line in lines if not line.startswith('libzip-')] == task['other_lines'], 'Unexpected unrelated series change'
            (destination / task['name']).write_bytes(data)
        result = {'name':task['name'],'url':task['url'],'type':task['type'],'status':'verified','sha256':digest,'size':len(data),'headers':headers,'observed_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
        if task['type'] == 'series':
            result['selected'] = selected[0]
        return result
    except Exception as e:
        return {'name':task['name'],'url':task['url'],'status':'pending','error':str(e)}

for attempt in range(20):
    pending = [t for t in tasks if t['name'] not in accepted]
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(verify,pending))
    for result in results:
        if result['status'] == 'verified':
            accepted[result['name']] = result
    report = {'status':'verified' if len(accepted)==len(tasks) else 'pending','verified':len(accepted),'expected':len(tasks),'results':list(accepted.values()),'pending':[r for r in results if r['status'] != 'verified']}
    (destination/'audit.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f"Canonical publication: {len(accepted)}/{len(tasks)} verified",flush=True)
    if len(accepted)==len(tasks):
        break
    if attempt < 19:
        time.sleep(30)
else:
    raise SystemExit('Canonical publication is not complete; see results/audit.json')
