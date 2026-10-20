"""Run a hash-pinned private QA bundle; publish only a status on this host."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile


def transfer(url, path, upload=False):
    for attempt in range(4):
        try:
            data = path.read_bytes() if upload else None
            headers = {'If-None-Match': '*', 'Cache-Control': 'private, no-store'} if upload else {}
            request = urllib.request.Request(url, data=data, method='PUT' if upload else 'GET', headers=headers)
            with urllib.request.urlopen(request, timeout=300) as response:
                if not upload:
                    with path.open('wb') as stream:
                        shutil.copyfileobj(response, stream)
            return
        except Exception:
            if attempt == 3:
                raise RuntimeError('Private evidence transfer failed') from None
            time.sleep(2 ** attempt)


def main():
    access = json.loads(os.environ.pop('PRIVATE_QA_ACCESS'))
    lane = os.environ['QA_LANE']
    if os.environ['GITHUB_RUN_ATTEMPT'] != '1':
        raise RuntimeError('New access ticket required for another attempt')
    slot = access['lanes'][lane]
    root = Path(tempfile.mkdtemp(prefix='private-qa-', dir=os.environ['RUNNER_TEMP']))
    bundle = root / 'bundle.zip'
    transfer(access['get'], bundle)
    if hashlib.sha256(bundle.read_bytes()).hexdigest() != access['sha256']:
        raise RuntimeError('Private bundle verification failed')
    payload = root / 'payload'
    with zipfile.ZipFile(bundle) as archive:
        for item in archive.infolist():
            destination = (payload / item.filename).resolve()
            if not destination.is_relative_to(payload.resolve()):
                raise RuntimeError('Invalid private bundle entry')
        archive.extractall(payload)
    result = root / 'result'
    result.mkdir()
    env = os.environ.copy()
    env['QA_RESULT_DIRECTORY'] = str(result)
    env['QA_PAYLOAD_DIRECTORY'] = str(payload)
    for name in ('ACTIONS_RUNTIME_TOKEN', 'ACTIONS_RUNTIME_URL', 'ACTIONS_RESULTS_URL', 'GITHUB_TOKEN', 'GH_TOKEN'):
        env.pop(name, None)
    started = time.time()
    with (result / 'execution.log').open('wb') as log:
        process = subprocess.Popen(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(payload / 'run.ps1'), '-Lane', lane], cwd=payload, env=env, stdout=log, stderr=subprocess.STDOUT)
        timed_out = False
        try:
            process.wait(timeout=165 * 60)
        except subprocess.TimeoutExpired:
            # Leave time to archive partial evidence before the 180-minute job limit.
            timed_out = True
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], stdout=log, stderr=subprocess.STDOUT, check=False)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=30)
            process.returncode = 124
    record = {'schema': 1, 'run_id': os.environ['GITHUB_RUN_ID'], 'attempt': 1,
              'revision': os.environ['GITHUB_SHA'], 'lane': lane, 'bundle_sha256': access['sha256'],
              'exit_code': process.returncode, 'timed_out': timed_out, 'seconds': time.time() - started,
              'files': {str(p.relative_to(result)): hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in result.rglob('*') if p.is_file()}}
    (result / 'result.json').write_text(json.dumps(record, indent=2))
    archive_path = root / 'result.zip'
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for p in result.rglob('*'):
            if p.is_file():
                archive.write(p, str(p.relative_to(result)))
    transfer(slot['put'], archive_path, upload=True)
    # A separate GET capability proves that the privately archived evidence is intact.
    verify = root / 'verify.zip'
    transfer(slot['get'], verify)
    if hashlib.sha256(verify.read_bytes()).digest() != hashlib.sha256(archive_path.read_bytes()).digest():
        raise RuntimeError('Private evidence verification failed')
    print('QA completed; detailed results were archived and verified privately.')
    return process.returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('Private QA setup or evidence transfer failed; inspect the private dispatch record.')
        sys.exit(2)
