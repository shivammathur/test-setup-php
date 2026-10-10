import csv
from datetime import datetime
import itertools
import json
import os
from pathlib import Path
import re
import statistics

VERSIONS = ['5.6', '7.0', '7.1', '7.2', '7.3', '7.4', '8.0', '8.1', '8.2', '8.3', '8.4', '8.5', '8.6', '8.7']
RUNNERS = {'macos-15': 'arm64', 'macos-15-intel': 'x86_64'}
WORKLOADS = ['php', 'imagick', 'imagick-mongodb']
EXPECTED = set(itertools.product(VERSIONS, RUNNERS.values(), WORKLOADS, [1, 2, 3]))
pattern = re.compile(r'^PHP ([\d.]+) / (macos-15(?:-intel)?) / (php|imagick|imagick-mongodb) / sample ([123])$')
rows, errors, seen = [], [], set()
for page in json.loads(Path('jobs.json').read_text()):
    for job in page['jobs']:
        match = pattern.fullmatch(job['name'])
        if not match:
            continue
        version, runner, workload, sample = match.groups()
        arch, sample = RUNNERS[runner], int(sample)
        identity = version, arch, workload, sample
        if identity in seen:
            errors.append(f'Duplicate measurement {identity}')
        seen.add(identity)
        step = next((s for s in job['steps'] if s['name'] == 'Measure setup-php'), {})
        passed = job['conclusion'] == 'success' and step.get('conclusion') == 'success'
        summary_path = Path('evidence-download') / f'installer-{version}-{runner}-{workload}-{sample}' / 'cold-summary.json'
        summary = json.loads(summary_path.read_text()) if summary_path.is_file() else {}
        valid = summary.get('php') == version and summary.get('arch') == arch and summary.get('workload') == workload and summary.get('sample') == sample and summary.get('errors') == [] and summary.get('source_builds') == []
        seconds = None
        if step.get('started_at') and step.get('completed_at'):
            seconds = (datetime.fromisoformat(step['completed_at'].replace('Z', '+00:00')) - datetime.fromisoformat(step['started_at'].replace('Z', '+00:00'))).total_seconds()
        if not passed or not valid or seconds is None or seconds < 0:
            errors.append(f'{identity}: job={job["conclusion"]}, evidence_valid={valid}, duration={seconds}')
        rows.append({'php': version, 'architecture': arch, 'workload': workload, 'sample': sample, 'seconds': seconds,
                     'verified': passed and valid, 'job_id': job['id'], 'job_url': job['html_url'],
                     'bootstrap_sha256': summary.get('bootstrap_sha256'), 'php_binary_sha256': summary.get('php_binary_sha256')})
if seen != EXPECTED:
    errors.append(f'Missing={sorted(EXPECTED-seen)}, unexpected={sorted(seen-EXPECTED)}')
rows.sort(key=lambda r: (VERSIONS.index(r['php']), r['architecture'], WORKLOADS.index(r['workload']), r['sample']))
report = Path('reports'); report.mkdir(exist_ok=True)
(report / 'measurements.json').write_text(json.dumps(rows, indent=2) + '\n')
with (report / 'measurements.csv').open('w') as output:
    writer = csv.DictWriter(output, fieldnames=['php','architecture','workload','sample','seconds','verified','job_id','job_url','bootstrap_sha256','php_binary_sha256'])
    writer.writeheader(); writer.writerows(rows)
aggregates = []
for version, arch, workload in itertools.product(VERSIONS, RUNNERS.values(), WORKLOADS):
    group = [r for r in rows if (r['php'], r['architecture'], r['workload']) == (version, arch, workload)]
    valid = [r for r in group if r['verified'] and r['seconds'] is not None]
    fingerprints = {r['php_binary_sha256'] for r in valid}
    if len(fingerprints) > 1:
        errors.append(f'{version}/{arch}/{workload}: PHP changed between samples')
    durations = [r['seconds'] for r in valid]
    aggregates.append({'php':version, 'architecture':arch, 'workload':workload, 'samples_seconds':durations,
                       'average_seconds':statistics.mean(durations) if len(durations)==3 else None})
(report / 'averages.json').write_text(json.dumps(aggregates, indent=2) + '\n')
lines = ['# setup-php runtime measurements', '', 'Fresh GitHub-hosted macOS 15 runners; unchanged setup-php v2; release/NTS PHP; coverage and tools disabled. Three independent runs per cell. Timings cover only the setup-php action, including PHP/extension downloads and configuration. Queueing, checkout, cold preparation and runtime verification are excluded. GitHub step timestamps have one-second resolution.', '', 'The three workloads are PHP alone, PHP + Imagick, and PHP + Imagick + MongoDB. No PHP source rebuild is allowed.', '']
source_run = os.environ.get('SOURCE_RUN') or os.environ.get('GITHUB_RUN_ID')
if source_run and os.environ.get('GITHUB_REPOSITORY'):
    lines[2:2] = [f"Source installation tests: https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{source_run}", '']
for arch in RUNNERS.values():
    lines += [f'## {arch}', '', '| PHP | PHP only (s) | + Imagick (s) | + Imagick + MongoDB (s) |', '| --- | ---: | ---: | ---: |']
    for version in VERSIONS:
        values = [next(a['average_seconds'] for a in aggregates if (a['php'],a['architecture'],a['workload'])==(version,arch,w)) for w in WORKLOADS]
        lines.append('| ' + version + ' | ' + ' | '.join('incomplete' if v is None else f'{v:.1f}' for v in values) + ' |')
    overall = []
    for workload in WORKLOADS:
        values = [r['seconds'] for r in rows if r['architecture']==arch and r['workload']==workload and r['verified'] and r['seconds'] is not None]
        overall.append(f'{statistics.mean(values):.1f}' if len(values)==42 else 'incomplete')
    lines += ['| **Average** | ' + ' | '.join(overall) + ' |', '']
lines += ['## Individual measurements', '', 'See `measurements.csv` for all 252 durations and job links, and `averages.json` for each three-sample set.', '']
if errors:
    lines += ['## Validation errors', ''] + ['- ' + e for e in errors]
text='\n'.join(lines)+'\n'
(report / 'summary.md').write_text(text)
(report / 'validation.json').write_text(json.dumps({'expected':len(EXPECTED),'measured':len(rows),'verified':sum(r['verified'] for r in rows),'errors':errors},indent=2)+'\n')
if os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output: output.write(text)
print(text)
if errors: raise SystemExit(1)
