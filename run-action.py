import json
import os
from pathlib import Path
import re
import subprocess
import sys

kind, version, strict, startup = sys.argv[1:]
root = Path('artifacts')
root.mkdir(exist_ok=True)
if startup == 'true':
    ini = subprocess.check_output(['php', '--ini'], text=True)
    scan_dir = re.search(r'Scan for additional .ini files in:\s*(.+)', ini).group(1)
    warning_ini = 'display_errors=On\ndisplay_startup_errors=On\nextension=/tmp/pecl-validation-missing.so\n'
    subprocess.run(['sudo', 'tee', str(Path(scan_dir) / '99-pecl-validation-startup.ini')], input=warning_ini, text=True, check=True, stdout=subprocess.DEVNULL)
    warning = subprocess.run(['php', '-r', 'echo phpversion("apcu");'], text=True, capture_output=True)
    (root / 'startup-stdout.txt').write_text(warning.stdout)
    (root / 'startup-stderr.txt').write_text(warning.stderr)
    assert 'Warning: PHP Startup:' in warning.stdout, 'Startup warnings were not enabled on stdout'

extensions = 'apcu-5.1.26, sqlsrv-5.13.0beta1' if kind == 'live' else 'apcu-0.0.0'
env = dict(os.environ, **{'php-version': version, 'extensions': extensions,
                         'fail-fast': strict, 'tools': 'none', 'coverage': 'none',
                         'ini-file': 'development'})
result = subprocess.run(['node', 'action/dist/index.js'], env=env, text=True, capture_output=True)
(root / 'action-stdout.txt').write_text(result.stdout)
(root / 'action-stderr.txt').write_text(result.stderr)
print(result.stdout)
print(result.stderr, file=sys.stderr)
output = re.sub(r'\x1b\[[0-9;]*m', '', result.stdout)
probe = subprocess.run(['php', '-d', 'display_errors=0', '-d', 'display_startup_errors=0', '-r', 'echo json_encode(["php" => PHP_VERSION, "apcu" => phpversion("apcu"), "sqlsrv" => phpversion("sqlsrv")]);'], text=True, capture_output=True)
state = json.loads(probe.stdout)
(root / 'php-state.json').write_text(json.dumps(state, indent=2) + '\n')
annotations = [line for line in output.splitlines() if line.startswith('::warning::')]
if kind == 'live':
    assert result.returncode == 0, f'Live PECL action failed: {result.returncode}'
    assert state['apcu'] == '5.1.26', state
    assert state['sqlsrv'] == '5.13.0-beta1', state
    assert not annotations, annotations
else:
    assert state['apcu'] and state['apcu'] != '0.0.0', state
    if strict == 'true':
        assert result.returncode != 0, 'Strict version mismatch must fail the action'
        assert 'but apcu-0.0.0 was requested' in output, output
        assert not annotations, annotations
    else:
        assert result.returncode == 0, f'Default fallback action failed: {result.returncode}'
        assert annotations == [f'::warning::Installed apcu-{state["apcu"]}, but apcu-0.0.0 was requested'], annotations
(root / 'results.json').write_text(json.dumps({'passed': True, 'kind': kind, 'php': version, 'strict': strict, 'startup': startup, 'action_exit': result.returncode, 'state': state, 'annotations': annotations}, indent=2) + '\n')
print('PASS: full action validation')
