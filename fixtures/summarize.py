import collections
import json
import os
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
groups = collections.defaultdict(list)
samples = []
for timing_file in sorted(root.glob('*/timing.json')):
    timing = json.loads(timing_file.read_text())
    report = json.loads(timing_file.with_name('report.json').read_text())
    assert timing['method'] == report['method'], timing_file
    assert report['php'] == '8.5.12' and not report['zts'], report
    assert all(report[key] for key in ('cleanAnalysisPassed', 'deliberateTypeErrorDetected', 'workerTurboActive')), report
    assert report['analysisTurboVersion'] == report['expectedTurboVersion'], report
    if timing['method'] == 'release':
        assert report['phpstanDiagnosisEnabled'] and report['turboVersion'] == report['expectedTurboVersion'], report
    groups[timing['os'], timing['method']].append(timing['elapsedSeconds'])
    samples.append({'timing': timing, 'validation': report})
assert len(samples) == 18, f'Expected 18 validated samples, found {len(samples)}'
assert len({sample['validation']['phpstanSha256'] for sample in samples}) == 1, 'PHPStan PHAR differs between installs'
assert len({sample['validation']['analysisTurboVersion'] for sample in samples}) == 1, 'Turbo versions differ'
rows = []
markdown = ['Median full setup duration, three fresh runners per OS and method; PHP 8.5.12, PHPStan 2.3.5, NTS.', '', '| OS | develop / Composer | PHAR + Turbo | Faster in this sample |', '|---|---:|---:|---|']
for runner_os in ('Linux', 'macOS', 'Windows'):
    values = {}
    for method in ('composer', 'release'):
        times = groups[runner_os, method]
        assert len(times) == 3, (runner_os, method, times)
        values[method] = {'medianSeconds': statistics.median(times), 'minSeconds': min(times), 'maxSeconds': max(times), 'samplesSeconds': sorted(times)}
    composer = values['composer']['medianSeconds']
    release = values['release']['medianSeconds']
    winner = 'PHAR + Turbo' if release < composer else 'Composer'
    row = {'os': runner_os, 'methods': values, 'winner': winner, 'releaseChangePercent': 100 * (release - composer) / composer}
    rows.append(row)
    markdown.append(f'| {runner_os} | {composer:.3f}s | {release:.3f}s | {winner} |')
summary = {'results': rows, 'samples': samples}
Path('benchmark-summary.json').write_text(json.dumps(summary, indent=2))
text = '\n'.join(markdown) + '\n'
print(text)
if os.getenv('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as handle:
        handle.write(text)
