"""Fetch small job pages: large pages can time out after a partial rerun."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import time

repository = os.environ['GITHUB_REPOSITORY']
run_id = os.environ.get('SOURCE_RUN') or os.environ['GITHUB_RUN_ID']
if not run_id.isdecimal():
    raise SystemExit('Invalid source run ID')
page_size = 10

def fetch(page):
    endpoint = f'repos/{repository}/actions/runs/{run_id}/jobs?per_page={page_size}&page={page}'
    for attempt in range(3):
        try:
            payload = json.loads(subprocess.check_output(['gh', 'api', endpoint], timeout=60))
            if not isinstance(payload.get('jobs'), list):
                raise ValueError('Missing jobs in API response')
            return payload
        except (subprocess.SubprocessError, ValueError):
            if attempt == 2:
                raise
            time.sleep(attempt + 1)

first = fetch(1)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    pages = [first, *pool.map(fetch, range(2, (first['total_count'] + page_size - 1) // page_size + 1))]
if sum(len(page['jobs']) for page in pages) != first['total_count']:
    raise SystemExit('Incomplete job inventory')
Path('jobs.json').write_text(json.dumps(pages) + '\n')
print(f"Collected {first['total_count']} jobs from run {run_id}")
