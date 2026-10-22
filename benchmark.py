import json
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

repos = {'base': str(Path(sys.argv[1]).resolve()), 'candidate': str(Path(sys.argv[2]).resolve())}
root = Path('artifacts').resolve()
fixtures = root / 'fixtures'
php = shutil.which('php')
samples, iterations = 16, 5
randomizer = random.Random(1141)
results = []
for case in ['enabled', 'cached', 'install-exact', 'fallback-mismatch', 'unpinned']:
    values = {'base': [], 'candidate': []}
    calls = {}
    with tempfile.TemporaryDirectory(prefix='pecl-benchmark-') as directory:
        for label, repo in repos.items():
            subprocess.run(['bash', 'benchmark.sh', repo, directory, case, php, str(fixtures), '1', 'true'], check=True)
            call_file = Path(directory) / 'php-calls.txt'
            calls[label] = len(call_file.read_text().splitlines())
            call_file.unlink()
        for sample in range(samples + 2):
            order = list(repos)
            randomizer.shuffle(order)
            for label in order:
                start = time.perf_counter()
                subprocess.run(['bash', 'benchmark.sh', repos[label], directory, case, php, str(fixtures), str(iterations), 'false'], check=True)
                elapsed = (time.perf_counter() - start) * 1000 / iterations
                if sample >= 2:
                    values[label].append(elapsed)
    medians = {label: statistics.median(times) for label, times in values.items()}
    paired_deltas = [candidate - base for base, candidate in zip(values['base'], values['candidate'])]
    result = {'case': case, 'samples': samples, 'iterations_per_sample': iterations,
              'php_calls': calls, 'median_ms': medians,
              'median_paired_delta_ms': statistics.median(paired_deltas), 'raw_ms': values}
    results.append(result)
    print(f'{case}: base={medians["base"]:.3f}ms candidate={medians["candidate"]:.3f}ms PHP calls={calls}')
    assert calls['candidate'] <= calls['base'], result
(root / 'benchmark.json').write_text(json.dumps(results, indent=2) + '\n')
