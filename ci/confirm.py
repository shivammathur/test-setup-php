import hashlib
import json
import os
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
artifact = root / 'known-builds/php83-x86-after'
metadata = json.loads((artifact / 'summary.json').read_text())
for name, expected in metadata['binary_sha256'].items():
    assert hashlib.sha256((artifact / 'bin' / name).read_bytes()).hexdigest() == expected
php = artifact / 'bin/php.exe'
evidence = root / 'confirmation-evidence'
evidence.mkdir()
results = []
for name, fixture, memory, expected in (
    ('original-128M', 'stack_limit_011.phpt', '128M', False),
    ('original-256M', 'stack_limit_011.phpt', '256M', True),
    ('upstream-test-128M', 'stack_limit_011_upstream.phpt', '128M', True),
):
    for iteration in range(1, 4):
        command = [str(php), '-n', str(root / 'php-src/run-tests.php'), '-p', str(php),
                   '-n', '-d', 'extension_dir=' + str(php.parent), '-d', 'memory_limit=' + memory,
                   '-q', '--offline', '--no-progress', '--show-out', '--show-diff',
                   '--set-timeout', '120', str(root / 'fixtures' / fixture)]
        proc = subprocess.run(command, cwd=root / 'php-src', text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        (evidence / (name + '-' + str(iteration) + '.log')).write_text(proc.stdout)
        passed = bool(re.search(r'PASS Stack limit 011', proc.stdout))
        failed = bool(re.search(r'FAIL Stack limit 011', proc.stdout))
        assert passed != failed, proc.stdout
        record = {'case': name, 'iteration': iteration, 'memory_limit': memory,
                  'passed': passed, 'exit_code': proc.returncode,
                  'oom': 'Allowed memory size of 134217728 bytes exhausted' in proc.stdout}
        results.append(record)
        print(json.dumps(record), flush=True)
        assert passed == expected, record
(evidence / 'summary.json').write_text(json.dumps({'source': metadata['source'],
    'binary_sha256': metadata['binary_sha256'], 'results': results}, indent=2))
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as handle:
    handle.write('```json\n' + json.dumps(results, indent=2) + '\n```\n')
