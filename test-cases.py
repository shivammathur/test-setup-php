import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

repo = Path(sys.argv[1]).resolve()
php = shutil.which('php')
root = Path('artifacts').resolve()
fixtures = root / 'fixtures'
cases = '''exact exact-strict enabled cached fallback-exact fallback-mismatch
unpinned unpinned-fallback missing strict-no-fallback strict-wrong-success
strict-wrong-failure wrong-success prerelease prerelease-strict prerelease-enabled
prerelease-cached startup-missing startup-missing-strict startup-target-missing-strict
startup-exact startup-cached startup-mismatch startup-wrong-strict'''.split()
results = []
for case in cases:
    directory = root / case
    directory.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(['bash', 'scenario.sh', str(repo), str(directory), case, php, str(fixtures)], text=True, capture_output=True)
    (directory / 'stdout.txt').write_text(result.stdout)
    (directory / 'stderr.txt').write_text(result.stderr)
    output = re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)
    errors = []
    manifest = directory / 'expected.txt'
    if not manifest.exists():
        errors.append('scenario failed before producing expectations')
    else:
        status, warnings, installs, fallbacks, cache, expected, requested = manifest.read_text().splitlines()
        env = dict(os.environ, PHP_INI_SCAN_DIR=str(directory / 'conf.d'))
        probe = subprocess.run([php, '-c', str(directory / 'php.ini'), '-d', 'display_errors=0', '-d', 'display_startup_errors=0', '-r', 'echo (int) extension_loaded("pecl_fixture"), "\\n", phpversion("pecl_fixture");'], env=env, text=True, capture_output=True)
        if probe.returncode:
            errors.append('PHP state probe failed: ' + probe.stderr)
            loaded, actual = False, False
        else:
            loaded_text, actual = probe.stdout.split('\n', 1)
            loaded, actual = loaded_text == '1', actual or False
        (directory / 'php-state.json').write_text(json.dumps([loaded, actual]) + '\n')
        assertions = {
            'exit status': result.returncode == int(status),
            'warning annotations': output.count('::warning::') == int(warnings),
            'installer calls': (directory / 'installer-calls.txt').exists() == bool(int(installs)),
            'fallback calls': (directory / 'fallback-calls.txt').exists() == bool(int(fallbacks)),
            'loaded state': loaded == bool(expected),
            'installed version': actual == (expected or False),
            'continuation': ('CONTINUED_AFTER_SETUP' in output) == (status == '0'),
            'normalized cache': (directory / 'extensions' / ('pecl_fixture-' + requested)).exists() == bool(int(cache)),
            'no diagnostic text in result': 'Warning: PHP Startup:' not in output,
        }
        if int(warnings):
            assertions['observed mismatch annotation'] = f'::warning::Installed pecl_fixture-{expected}, but pecl_fixture-{requested} was requested' in output
            assertions['no false PECL failure claim'] = 'from PECL' not in output
            assertions['no green success'] = '✓' not in output
        elif not expected or int(status):
            assertions['error result'] = '✗' in output and '✓' not in output
        else:
            assertions['success result'] = '✓' in output and '✗' not in output
        errors.extend(name for name, passed in assertions.items() if not passed)
    results.append({'case': case, 'passed': not errors, 'errors': errors, 'exit_code': result.returncode})
    print(f'{"PASS" if not errors else "FAIL"}: {case}' + (': ' + ', '.join(errors) if errors else ''))
    if errors:
        print(output)
        print(result.stderr)
(root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
if not all(result['passed'] for result in results):
    sys.exit(1)
