"""Collect every installer artifact with bounded, paced GitHub API requests."""
import concurrent.futures
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import threading
import time
import zipfile

_lock = threading.Lock()
_next_request = 0.0


def api(endpoint):
    global _next_request
    for attempt in range(5):
        with _lock:
            delay = max(0, _next_request - time.monotonic())
            time.sleep(delay)
            _next_request = time.monotonic() + 0.35
        try:
            result = subprocess.run(['gh', 'api', endpoint], capture_output=True, timeout=90)
            if result.returncode == 0:
                return result.stdout
            error = result.stderr.decode(errors='replace')
        except subprocess.TimeoutExpired as exception:
            error = str(exception)
        if attempt == 4:
            raise RuntimeError(error)
        time.sleep(15 * (attempt + 1))


def inventory(repository, run_id):
    artifacts = []
    page = 1
    total = None
    while total is None or len(artifacts) < total:
        response = json.loads(api(f'repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100&page={page}'))
        total = response['total_count']
        if not response['artifacts'] and len(artifacts) < total:
            raise ValueError('Incomplete artifact inventory')
        artifacts.extend(response['artifacts'])
        page += 1
    assert len(artifacts) == total and len({a['id'] for a in artifacts}) == total, 'Invalid artifact inventory'
    return artifacts


def download(repository, artifact, destination):
    name = artifact['name']
    assert name.startswith('installer-') and '/' not in name and '..' not in name, name
    assert not artifact['expired'], name
    raw = api(f'repos/{repository}/actions/artifacts/{artifact["id"]}/zip')
    digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
    assert digest == artifact['digest'], f'{name}: artifact checksum mismatch'
    target = destination / name
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        assert all(not PurePosixPath(m.filename).is_absolute() and '..' not in PurePosixPath(m.filename).parts
                   and '\\' not in m.filename and (m.external_attr >> 16) & 0o170000 != 0o120000
                   for m in archive.infolist()), f'{name}: unsafe archive member'
        target.mkdir(parents=True, exist_ok=True)
        archive.extractall(target)
    return {'id': artifact['id'], 'name': name, 'digest': digest}


def main():
    repository = os.environ['GITHUB_REPOSITORY']
    run_id = os.environ.get('SOURCE_RUN') or os.environ['GITHUB_RUN_ID']
    assert run_id.isdecimal(), 'Invalid source run ID'
    artifacts = [a for a in inventory(repository, run_id) if a['name'].startswith('installer-')]
    assert len({a['name'] for a in artifacts}) == len(artifacts), 'Duplicate installer artifacts'
    destination = Path('evidence-download')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        verified = list(pool.map(lambda artifact: download(repository, artifact, destination), artifacts))
    Path('artifact-inventory.json').write_text(json.dumps(verified, indent=2) + '\n')
    print(f'Downloaded and checksum-verified {len(verified)} installer artifacts from run {run_id}')


if __name__ == '__main__':
    main()
