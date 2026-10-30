import hashlib
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
evidence = root / 'profile-evidence'
evidence.mkdir(exist_ok=True)
phpt = (root / 'fixtures/stack_limit_011.phpt').read_text()
code = phpt.split('--FILE--\n', 1)[1].split('--EXPECTF--', 1)[0].rstrip()
assert code.endswith('?>')
code = code[:-2] + '''
$peak = memory_get_peak_usage(true);
$exceptionCount = 0;
$traceFrames = 0;
$maxTraceFrames = 0;
for ($current = $e ?? null; $current !== null; $current = $current->getPrevious()) {
    $exceptionCount++;
    $frames = count($current->getTrace());
    $traceFrames += $frames;
    $maxTraceFrames = max($maxTraceFrames, $frames);
}
echo "DIAGNOSTICS ", json_encode(compact('peak', 'exceptionCount', 'traceFrames', 'maxTraceFrames')), "\\n";
'''
script = evidence / 'profile.php'
script.write_text(code)
results = []
for variant in ('before', 'after', 'revert-pcre'):
    artifact = root / 'known-builds' / ('php83-x86-' + variant)
    metadata = json.loads((artifact / 'summary.json').read_text())
    for name, expected in metadata['binary_sha256'].items():
        actual = hashlib.sha256((artifact / 'bin' / name).read_bytes()).hexdigest()
        assert actual == expected, (variant, name)
    php = artifact / 'bin/php.exe'
    for memory in ('128M', '1024M'):
        proc = subprocess.run([str(php), '-n', '-d', 'extension_dir=' + str(php.parent), '-d', 'extension=php_zend_test.dll', '-d', 'zend.max_allowed_stack_size=256K', '-d', 'memory_limit=' + memory, str(script)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        (evidence / (variant + '-' + memory + '.txt')).write_text(proc.stdout)
        match = re.search(r'DIAGNOSTICS (\{.*\})', proc.stdout)
        record = {'variant': variant, 'memory': memory, 'exit_code': proc.returncode, 'diagnostics': json.loads(match[1]) if match else None}
        results.append(record)
        print(json.dumps(record), flush=True)
(evidence / 'summary.json').write_text(json.dumps(results, indent=2))
