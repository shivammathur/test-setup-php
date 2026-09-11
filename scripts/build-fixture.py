import os
import signal
import subprocess
import sys
import time
from pathlib import Path

root = Path(os.environ['TEST_ROOT'])
role = sys.argv[1] if len(sys.argv) > 1 else 'brew'
if role == 'brew':
    if (root / 'pids').exists():
        for pid in (root / 'pids').read_text().splitlines():
            state = subprocess.run(['ps', '-p', pid, '-o', 'stat='], capture_output=True, text=True)
            if state.returncode == 0 and not state.stdout.strip().startswith('Z'):
                with (root / 'overlap').open('a') as file:
                    file.write(pid + '\n')
    with (root / 'attempts').open('a') as file:
        file.write('attempt\n')
    print('==> make', flush=True)
with (root / 'pids').open('a') as file:
    file.write(str(os.getpid()) + '\n')
if role == 'compiler':
    signal.signal(signal.SIGTERM, lambda *_: None)
    if os.environ.get('TEST_BUILD_DURATION'):
        time.sleep(float(os.environ['TEST_BUILD_DURATION']))
        sys.exit(0)
    while True:
        time.sleep(1)
else:
    output = subprocess.DEVNULL if os.environ.get('TEST_BUILD_STDIO', 'ignore') == 'ignore' else None
    child = subprocess.Popen(
        [sys.executable, os.environ['TEST_BUILD_SCRIPT'], 'builder' if role == 'brew' else 'compiler'],
        start_new_session=True, stdout=output, stderr=output,
    )
    code = child.wait()
    if role == 'brew':
        (root / 'built').write_text('done')
        time.sleep(float(os.environ.get('TEST_AFTER_BUILD_DELAY', '0')))
    sys.exit(code)
