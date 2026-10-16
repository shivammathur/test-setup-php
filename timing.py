import json
import os
from pathlib import Path
import subprocess
import time

results = []
for trial in range(3):
    start = time.perf_counter()
    output = subprocess.run(['php', '-r', 'echo PHP_VERSION;'], check=True, text=True, capture_output=True)
    assert not output.stderr, output.stderr
    results.append(dict(trial=trial+1, version=output.stdout, seconds=round(time.perf_counter()-start, 3)))
print(json.dumps(results, indent=2))
(Path(os.environ['RUNNER_TEMP'])/'report/startup.json').write_text(json.dumps(results, indent=2))
