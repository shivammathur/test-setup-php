import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import zipfile

WORKSPACE = Path.cwd()
SOURCE = WORKSPACE / 'php-src'
RESULTS = WORKSPACE / 'results'
ROOT = Path(os.environ.get('SystemDrive', 'C:') + '/pr11669')
RESULTS.mkdir(exist_ok=True)
ROOT.mkdir(exist_ok=True)
BUILD = {key.lower(): os.environ['QA_' + key] for key in ['BRANCH', 'SHA', 'BEFORE', 'BUILD_RUN', 'ARCH', 'TS']}
TESTS = [
    'ext/standard/tests/file/bug60120.phpt',
    'ext/standard/tests/general_functions/proc_open_null.phpt',
    'ext/standard/tests/general_functions/proc_open_redirect.phpt',
    'ext/standard/tests/general_functions/proc_open_sockets1.phpt',
    'ext/standard/tests/general_functions/proc_open_sockets2.phpt',
    'ext/standard/tests/general_functions/proc_open_sockets3.phpt',
    'ext/standard/tests/ini_info/php_ini_loaded_file.phpt',
    'sapi/cli/tests/016.phpt',
    'sapi/cli/tests/023.phpt',
    'sapi/cli/tests/bug65275.phpt',
    'sapi/cli/tests/bug74600.phpt',
    'sapi/cli/tests/bug78323.phpt',
]
FIXTURES = [
    'ext/standard/tests/ini_info/loaded.ini',
    'ext/standard/tests/general_functions/proc_open_sockets1.inc',
    'ext/standard/tests/general_functions/proc_open_sockets2.inc',
    'sapi/cli/tests/skipif.inc', 'sapi/cli/tests/bug65275.inc',
]
PROC_TESTS = TESTS[1:6]
RECORDS = []


def execute(command, logfile, env, cwd=ROOT, timeout=180):
    """Do not lose evidence on timeout or a Windows exception exit status."""
    started = time.monotonic()
    with logfile.open('wb') as output:
        process = subprocess.Popen([str(x) for x in command], cwd=cwd, env=env,
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            code = process.wait(timeout=30)
            timed_out = True
    return {'exit': code, 'exit_hex': f'{code & 0xffffffff:08X}',
            'timeout': timed_out, 'seconds': round(time.monotonic() - started, 3)}


def pe_machine(path):
    with path.open('rb') as stream:
        if stream.read(2) != b'MZ':
            raise ValueError(f'{path} is not a PE file')
        stream.seek(0x3c)
        offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset)
        if stream.read(4) != b'PE\x00\x00':
            raise ValueError(f'{path} has an invalid PE signature')
        return struct.unpack('<H', stream.read(2))[0]


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2), encoding='utf-8')


def persist():
    write_json(RESULTS / 'summary.json', {'build': BUILD, 'cases': RECORDS})


pattern = re.compile(r'^php-\d.+-(?:nts-)?Win32-v[sc]\d+-' + BUILD['arch'] + r'\.zip$')
candidates = [p for p in (WORKSPACE / 'artifacts').glob('*.zip')
              if pattern.match(p.name) and (('-nts-' in p.name) == (BUILD['ts'] == 'nts'))]
if len(candidates) != 1:
    raise RuntimeError(f'Expected one runtime artifact, got {candidates}')
archive = candidates[0]
runtime = ROOT / 'php'
with zipfile.ZipFile(archive) as package:
    members = package.namelist()
    package.extractall(runtime)
php = runtime / 'php.exe'
if not php.exists():
    raise RuntimeError('The selected runtime archive has no top-level php.exe')
expected_machine = 0x8664 if BUILD['arch'] == 'x64' else 0x14c
machines = {str(p.relative_to(runtime)): f'{pe_machine(p):04X}'
            for p in runtime.rglob('*') if p.suffix.lower() in {'.dll', '.exe'}}
for filename, machine in machines.items():
    if int(machine, 16) != expected_machine:
        raise RuntimeError(f'Unexpected PE machine {machine} in {filename}')
write_json(RESULTS / 'artifact.json', {
    'build': BUILD, 'archive': archive.name, 'bytes': archive.stat().st_size,
    'sha256': hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest(),
    'members': members, 'pe_machines': machines,
})
ext = runtime / 'ext'
cache = runtime / 'file-cache'
cache.mkdir(exist_ok=True)
empty_scan = ROOT / 'empty-scan'
empty_scan.mkdir(exist_ok=True)
ini = runtime / 'php.ini'
ini_lines = [f'extension_dir="{ext}"', 'date.timezone=UTC',
             f'opcache.file_cache="{cache}"', 'opcache.record_warnings=1',
             'opcache.enable_cli=0', 'display_errors=1', 'display_startup_errors=1',
             'log_errors=0']
if (ext / 'php_opcache.dll').exists():
    ini_lines.append(f'zend_extension="{ext / "php_opcache.dll"}"')
for extension in ['openssl', 'sockets']:
    if (ext / f'php_{extension}.dll').exists():
        ini_lines.append(f'extension={extension}')
ini.write_text('\n'.join(ini_lines) + '\n', encoding='ascii')
shutil.copy2(ini, RESULTS / 'runtime.ini')
env = os.environ.copy()
env.update({'PHPRC': str(ini), 'PHP_INI_SCAN_DIR': str(empty_scan),
            'REPORT_EXIT_STATUS': '1', 'NO_INTERACTION': '1',
            'SKIP_IO_CAPTURE_TESTS': '1', 'SKIP_ONLINE_TESTS': '1'})
env['PATH'] = str(runtime) + os.pathsep + env['PATH']
for variable in ['TEST_PHP_EXECUTABLE', 'TEST_PHP_ARGS', 'TEST_PHP_EXTRA_ARGS',
                 'TEST_PHP_CGI_EXECUTABLE', 'TEST_PHPDBG_EXECUTABLE']:
    env.pop(variable, None)
info = execute([php, '-r', 'echo json_encode(["version"=>PHP_VERSION,"zts"=>PHP_ZTS,"int_size"=>PHP_INT_SIZE,"extensions"=>get_loaded_extensions()]);'],
               RESULTS / 'runtime.json', env)
if info['exit'] != 0:
    raise RuntimeError(f'Runtime startup failed: {info}')
runtime_info = json.loads((RESULTS / 'runtime.json').read_text())
if bool(runtime_info['zts']) != (BUILD['ts'] == 'ts') or runtime_info['int_size'] != (8 if BUILD['arch'] == 'x64' else 4):
    raise RuntimeError(f'Runtime architecture/TS mismatch: {runtime_info}')
source_version = re.search(r'^#define PHP_VERSION "([^"]+)"', (SOURCE / 'main/php_version.h').read_text(), re.M).group(1)
if runtime_info['version'] != source_version:
    raise RuntimeError(f'Runtime {runtime_info["version"]} does not match source {source_version}')
print(json.dumps({'artifact': archive.name, 'runtime': runtime_info}), flush=True)

snapshots = {}
for revision, ref in [('before', BUILD['before']), ('after', BUILD['sha'])]:
    snapshots[revision] = {}
    for file in TESTS + FIXTURES:
        snapshots[revision][file] = subprocess.check_output(['git', 'show', ref + ':' + file], cwd=SOURCE)


def options(mode, identifier):
    enabled = mode != 'off'
    settings = {
        'extension_dir': str(ext), 'opcache.enable': int(enabled),
        'opcache.enable_cli': int(enabled), 'opcache.protect_memory': 1,
        'opcache.jit_buffer_size': '64M' if mode == 'tracing' else '0',
        'opcache.jit': 'tracing' if mode == 'tracing' else 'disable',
        'opcache.cache_id': identifier,
    }
    return [item for key, value in settings.items() for item in ['-d', f'{key}={value}']]


def phpt(revision, scenario, mode, selected=TESTS, extra=(), patch=None):
    identifier = f'{revision}-{scenario}-{mode}'
    dest = ROOT / ('source space' if scenario == 'source-space' else 'sources') / identifier
    dest.mkdir(parents=True, exist_ok=True)
    for file, data in snapshots[revision].items():
        target = dest / file
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    if patch:
        for file in selected:
            target = dest / file
            target.write_text(patch(target.read_text()), encoding='utf-8', newline='')
    # Keep the runner and runtime identical; only the test revision differs.
    shutil.copy2(SOURCE / 'run-tests.php', dest / 'run-tests.php')
    test_php = php
    if scenario == 'binary-space':
        spaced = ROOT / 'php bin'
        if not spaced.exists():
            shutil.copytree(runtime, spaced)
        test_php = spaced / 'php.exe'
    case_dir = RESULTS / identifier
    case_dir.mkdir(exist_ok=True)
    case_env = env.copy()
    case_env['TEST_PHP_JUNIT'] = str(case_dir / 'junit.xml')
    command = [test_php, '-n', dest / 'run-tests.php', '-p', test_php,
               '-q', '--no-progress', '--show-diff', '--set-timeout', '20', '-j1',
               *options(mode, identifier), *extra, *selected]
    record = {'kind': 'phpt', 'revision': revision, 'scenario': scenario, 'mode': mode,
              'command': [str(x) for x in command]}
    record.update(execute(command, case_dir / 'run.log', case_env, cwd=dest))
    log = (case_dir / 'run.log').read_text(errors='replace')
    record['tests'] = [{'status': match[0], 'description': match[1]}
                       for match in re.findall(r'^(PASS|FAIL|SKIP|BORK|WARN|XFAIL|XLEAK) (.*)$', log, re.M)]
    for suffix in ['.diff', '.out', '.exp', '.log', '.php', '.sh']:
        for file in selected:
            evidence = (dest / file).with_suffix(suffix)
            if evidence.exists():
                target = case_dir / 'tests' / evidence.relative_to(dest)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(evidence, target)
    RECORDS.append(record)
    persist()
    counts = {status: sum(test['status'] == status for test in record['tests'])
              for status in ['PASS', 'FAIL', 'SKIP', 'BORK']}
    print(json.dumps({'case': identifier, 'exit': record['exit'], 'timeout': record['timeout'], **counts}), flush=True)
    if record['timeout'] or len(record['tests']) != len(selected):
        raise RuntimeError(f'Incomplete PHPT run: {identifier}')


for mode in ['off', 'opcache', 'tracing']:
    for revision in ['before', 'after']:
        phpt(revision, 'normal', mode)
for revision in ['before', 'after']:
    phpt(revision, 'no-ini', 'off', extra=['-n'])
    phpt(revision, 'binary-space', 'off', selected=PROC_TESTS)
    phpt(revision, 'source-space', 'off', selected=PROC_TESTS)
    phpt(revision, 'custom-ini', 'off', selected=[TESTS[6]], extra=['-c', str(ini)])

def bypass_shell(code):
    # All affected calls have exactly three arguments before this diagnostic edit.
    return code.replace(', $pipes);', ", $pipes, null, null, ['bypass_shell' => true]);")

phpt('after', 'bypass-shell', 'tracing', selected=PROC_TESTS, patch=bypass_shell)
for repeat in range(2):
    phpt('after', f'repeat-{repeat}', 'tracing', selected=PROC_TESTS)

# Capture child crash codes independently, changing one dimension at a time.
variants = ['file-string', 'bypass-shell', 'array-file', 'array-inline', 'no-extra-args',
            'no-child-opcache', 'no-child-jit', 'no-child-optimizer',
            'no-child-protection', 'echo-only', 'stderr-only']
for mode in ['off', 'opcache', 'tracing']:
    for variant in variants:
        identifier = f'probe-{mode}-{variant}'
        args = options(mode, identifier) + [
            '-d', 'opcache.file_update_protection=0', '-d', 'opcache.revalidate_freq=0',
            '-d', 'opcache.jit_hot_func=1', '-d', 'opcache.jit_hot_loop=1',
            '-d', 'opcache.jit_hot_return=1', '-d', 'opcache.jit_hot_side_exit=1',
            '-d', 'output_buffering=0', '-d', 'display_errors=1', '-d', 'log_errors=0',
        ]
        config = ROOT / (identifier + '.json')
        write_json(config, {'args': args})
        logpath = RESULTS / (identifier + '.log')
        record = {'kind': 'probe', 'variant': variant, 'mode': mode}
        record.update(execute([php, *args, WORKSPACE / 'qa/probe.php', config, variant], logpath, env, timeout=90))
        log = logpath.read_text(errors='replace')
        record['children'] = [json.loads(value) for value in re.findall(r'^RESULT (.*)$', log, re.M)]
        RECORDS.append(record)
        persist()
        failures = [child for child in record['children'] if child['exit'] != 0]
        print(json.dumps({'case': identifier, 'exit': record['exit'], 'children': len(record['children']), 'failures': failures}), flush=True)
        if record['timeout'] or record['exit'] != 0 or len(record['children']) != 12:
            raise RuntimeError(f'Incomplete diagnostic probe: {identifier}')

lines = ['| Case | Passed | Failed | Skipped |', '|---|---:|---:|---:|']
for record in RECORDS:
    if record['kind'] == 'phpt':
        counts = [sum(test['status'] == status for test in record['tests']) for status in ['PASS', 'FAIL', 'SKIP']]
        lines.append(f'| {record["revision"]} / {record["scenario"]} / {record["mode"]} | ' + ' | '.join(map(str, counts)) + ' |')
(RESULTS / 'summary.md').write_text('\n'.join(lines) + '\n')
if 'GITHUB_STEP_SUMMARY' in os.environ:
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write('\n'.join(lines) + '\n')
print('Investigation complete; observed test failures are recorded in the evidence artifacts.', flush=True)
