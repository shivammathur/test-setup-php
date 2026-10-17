#!/usr/bin/env python3
"""Warm-run benchmark of two pinned revisions with rotating execution order."""
import csv
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import time

root = Path.cwd()
results = root / 'results'
results.mkdir(exist_ok=True)
revisions = {name: root / f'action-{name}' for name in ('baseline', 'candidate')}
records = []

def function(source, name):
    match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)
    if match is None:
        raise RuntimeError(f'Missing function {name}')
    return match.group(0)

def timed(command, label, env=None):
    log = results / f'{label}.log'
    started = time.perf_counter()
    with log.open('w') as output:
        process = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT)
    elapsed = time.perf_counter() - started
    if process.returncode:
        print(log.read_text())
        raise RuntimeError(f'{label}: exit {process.returncode}')
    return elapsed

def environment(label):
    env = os.environ.copy()
    env.update({
        'runner': 'self-hosted', 'update': 'false', 'fail-fast': 'true',
        'php-version': '8.4', 'extensions': 'mbstring,xml,curl',
        'tools': 'none', 'coverage': 'none', 'ini-values': 'memory_limit=256M',
    })
    for name in ('GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_OUTPUT'):
        file = results / f'{label}-{name.lower()}.txt'
        file.touch()
        env[name] = str(file)
    return env

def validate_php():
    code = '''
    if (PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 4) { throw new Exception(PHP_VERSION); }
    foreach (['mbstring', 'xml', 'curl'] as $extension) {
        if (!extension_loaded($extension)) { throw new Exception($extension); }
    }
    if (ini_get('memory_limit') !== '256M') { throw new Exception('memory_limit'); }
    '''
    subprocess.run(['php', '-r', code], check=True)

commands = {}
for name, directory in revisions.items():
    source = (directory / 'src/scripts/linux.sh').read_text()
    names = ['install_packages', 'self_hosted_helper']
    checks = [function(source, 'filter_packages')]
    script = results / f'{name}-helper.sh'
    script.write_text('\n'.join([
        '#!/usr/bin/env bash', 'set -eo pipefail', 'os=Linux',
        'apt_install="sudo DEBIAN_FRONTEND=noninteractive apt-fast install -y --no-install-recommends"',
        'update_lists() { echo "Unexpected apt failure during benchmark" >&2; return 1; }',
        *(function(source, item) for item in names), *checks, 'self_hosted_helper', '',
    ]))
    commands[name] = ['bash', str(script)]

metadata = {
    'os': os.environ['BENCHMARK_OS'], 'package_manager': os.environ['PACKAGE_MANAGER'],
    'architecture': platform.machine(), 'image_version': os.getenv('ImageVersion'),
    'baseline': os.environ['BASELINE_SHA'], 'candidate': os.environ['CANDIDATE_SHA'],
    'method': 'Same runner, two warmups per revision, balanced rotating AB/BA order; preparation excluded',
    'full_setup': 'PHP 8.4 self-hosted mode, mbstring/xml/curl, tools and coverage disabled',
}
(results / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')

for scope, samples in [('dependency_helper', 100), ('full_setup', 12)]:
    if scope == 'full_setup':
        commands = {name: ['node', str(directory / 'dist/index.js')] for name, directory in revisions.items()}
    for warmup in range(2):
        for name in revisions:
            label = f'{scope}-{name}-warmup-{warmup}'
            timed(commands[name], label, environment(label))
            if scope == 'full_setup':
                validate_php()
    for sample in range(samples):
        names = list(revisions)
        offset = sample % len(names)
        order = names[offset:] + names[:offset]
        for name in order:
            label = f'{scope}-{name}-{sample}'
            elapsed = timed(commands[name], label, environment(label))
            if scope == 'full_setup':
                validate_php()
            record = {'scope': scope, 'revision': name, 'sample': sample, 'seconds': elapsed}
            records.append(record)
            print(json.dumps(record), flush=True)
            (results / 'timings.json').write_text(json.dumps(records, indent=2) + '\n')

with (results / 'timings.csv').open('w') as output:
    writer = csv.DictWriter(output, fieldnames=['scope', 'revision', 'sample', 'seconds'])
    writer.writeheader()
    writer.writerows(records)
summary = []
for scope in ('dependency_helper', 'full_setup'):
    values = {name: [r['seconds'] for r in records if r['scope'] == scope and r['revision'] == name] for name in revisions}
    medians = {name: statistics.median(times) for name, times in values.items()}
    for comparison in ('baseline',):
        summary.append({
            'scope': scope, 'comparison': comparison,
            'baseline_seconds': medians[comparison], 'candidate_seconds': medians['candidate'],
            'saved_seconds': medians[comparison] - medians['candidate'],
            'reduction_percent': 100 * (1 - medians['candidate'] / medians[comparison]),
            'samples_per_revision': len(values[comparison]),
        })
(results / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
table = ['| Scope | Compare with | Before | After | Saved | Reduction |', '|---|---|---:|---:|---:|---:|']
for row in summary:
    table.append(f"| {row['scope']} | {row['comparison']} | {row['baseline_seconds']:.3f}s | {row['candidate_seconds']:.3f}s | {row['saved_seconds']:.3f}s | {row['reduction_percent']:.1f}% |")
report = f"### {metadata['os']} / {metadata['package_manager']}\n\n" + '\n'.join(table) + '\n\n' + metadata['method'] + '.\n'
(results / 'summary.md').write_text(report)
print(report)
if os.getenv('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
        output.write(report)
subprocess.run(['php', '-v'], check=True, stdout=(results / 'php-version.txt').open('w'))
subprocess.run(['php', '-m'], check=True, stdout=(results / 'php-modules.txt').open('w'))
