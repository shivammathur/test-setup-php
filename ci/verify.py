import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import time

root = pathlib.Path(__file__).resolve().parent.parent
source = root / 'php-src'
evidence = root / 'evidence'
build = pathlib.Path(r'C:\obj\Release')
php = build / 'php.exe'
deps = pathlib.Path(r'C:\build-cache\deps-8.3-vs16-x86')
for dll in (deps / 'bin').glob('*.dll'):
    shutil.copy2(dll, build / dll.name)
(build / 'php.ini').write_text('extension_dir=' + str(build) + '\nextension=php_openssl.dll\nextension=php_sockets.dll\n')
sdk_sha = subprocess.check_output(['git', '-C', r'C:\build-cache\sdk', 'rev-parse', 'HEAD'], text=True).strip()
assert sdk_sha == 'cfe7325dfdc9f20e54e85fb8929e32625d5f624e', sdk_sha
info = subprocess.check_output([str(php), '-r', 'echo json_encode(["version"=>PHP_VERSION,"int_size"=>PHP_INT_SIZE,"zts"=>PHP_ZTS,"debug"=>PHP_DEBUG,"memory_limit"=>ini_get("memory_limit")]);'], text=True)
runtime = json.loads(info)
assert runtime['int_size'] == 4 and runtime['zts'] == 0 and runtime['debug'] == 0, runtime
print('Runtime:', runtime, flush=True)
test = source / 'Zend/tests/stack_limit/stack_limit_011.phpt'
results = []
for iteration in range(1, 4):
    output = evidence / ('repeat-' + str(iteration))
    output.mkdir()
    start = time.monotonic()
    proc = subprocess.run([str(php), '-d', 'output_buffering=0', 'run-tests.php', '-p', str(php), '-q', '--offline', '--no-progress', '--show-diff', '--show-out', '--keep-all', '--set-timeout', '120', str(test)], cwd=source, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    (output / 'run-tests.log').write_text(proc.stdout)
    for path in test.parent.glob('stack_limit_011.*'):
        shutil.copy2(path, output / path.name)
    passed = bool(re.search(r'PASS Stack limit 011', proc.stdout))
    failed = bool(re.search(r'FAIL Stack limit 011', proc.stdout))
    assert passed != failed, proc.stdout
    result = {'iteration': iteration, 'exit_code': proc.returncode, 'passed': passed, 'seconds': round(time.monotonic() - start, 3), 'oom': 'Allowed memory size of 134217728 bytes exhausted' in proc.stdout}
    results.append(result)
    print(json.dumps(result), flush=True)
binary_dir = evidence / 'bin'
binary_dir.mkdir()
hashes = {}
for name in ('php.exe', 'php8.dll', 'php_zend_test.dll'):
    path = build / name
    shutil.copy2(path, binary_dir / name)
    hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
for name in ('php8.pdb', 'php.pdb', 'php_zend_test.pdb'):
    if (build / name).exists():
        shutil.copy2(build / name, binary_dir / name)
for relative in ('Zend/zend_execute_API.obj', 'Zend/zend_objects.obj', 'Zend/zend_execute.obj', 'Zend/zend_builtin_functions.obj', 'Zend/zend_alloc.obj', 'ext/pcre/php_pcre.obj'):
    path = build / relative
    if path.exists():
        shutil.copy2(path, binary_dir / path.name)
summary = {'variant': os.environ['VARIANT'], 'source': (evidence / 'source-ref.txt').read_text().strip(), 'sdk_sha': sdk_sha, 'runtime': runtime, 'results': results, 'binary_sha256': hashes}
(evidence / 'summary.json').write_text(json.dumps(summary, indent=2))
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as handle:
    handle.write('```json\n' + json.dumps(summary, indent=2) + '\n```\n')
print(json.dumps(summary, indent=2), flush=True)
