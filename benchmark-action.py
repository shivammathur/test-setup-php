import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import time

root = Path('artifacts')
root.mkdir(exist_ok=True)
version = subprocess.check_output(['php', '-r', 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;'], text=True)
apcu = subprocess.check_output(['php', '-r', 'echo phpversion("apcu");'], text=True)
assert apcu
env = dict(os.environ, **{'php-version': version, 'extensions': 'apcu-' + apcu,
                         'tools': 'none', 'coverage': 'none', 'fail-fast': 'true',
                         'ini-file': 'production'})
values = {'base': [], 'candidate': []}
randomizer = random.Random(1141)
for pair in range(10):
    order = ['base', 'candidate']
    randomizer.shuffle(order)
    for label in order:
        checkout = 'baseline' if label == 'base' else 'action'
        start = time.perf_counter()
        result = subprocess.run(['node', f'{checkout}/dist/index.js'], env=env, text=True, capture_output=True)
        elapsed = time.perf_counter() - start
        (root / f'action-{pair}-{label}.txt').write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stdout + result.stderr
        assert '::warning::' not in result.stdout, result.stdout
        if pair >= 2:
            values[label].append(elapsed)
summary = {'samples': 8, 'php': version, 'apcu': apcu,
           'median_seconds': {label: statistics.median(times) for label, times in values.items()},
           'median_paired_delta_seconds': statistics.median([candidate - base for base, candidate in zip(values['base'], values['candidate'])]),
           'raw_seconds': values}
(root / 'action-benchmark.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
