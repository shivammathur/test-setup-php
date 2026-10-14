import json
import os
import subprocess
import time

run = os.environ['BUILD_RUN']
repo = 'shivammathur/php-windows-builder'
for attempt in range(350):
    artifacts = json.loads(subprocess.check_output(['gh', 'api', f'repos/{repo}/actions/runs/{run}/artifacts']))
    if any(a['name'] == 'artifacts' and not a['expired'] for a in artifacts['artifacts']):
        print(f'Build {run}: merged artifacts are available', flush=True)
        break
    status = json.loads(subprocess.check_output(['gh', 'api', f'repos/{repo}/actions/runs/{run}']))
    if status['status'] == 'completed':
        raise SystemExit(f"Build {run} completed ({status['conclusion']}) without merged artifacts")
    if attempt % 10 == 0:
        print(f'Build {run}: waiting for merged artifacts', flush=True)
    time.sleep(30)
else:
    raise SystemExit(f'Timed out waiting for build {run}')
