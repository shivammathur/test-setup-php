<?php

declare(strict_types=1);

if ($argc < 2) {
    fwrite(STDERR, "Usage: php aggregate_results.php <results-directory>\n");
    exit(2);
}

$root = $argv[1];
$files = [];
$iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));

foreach ($iterator as $file) {
    if ($file->isFile() && preg_match('/\.json$/', $file->getFilename())) {
        $files[] = $file->getPathname();
    }
}

sort($files);

$runs = [];
$allIds = [];
$failures = [];
$probeIds = [
    'artifact-calling-conventions/vectorcall-partial',
    'artifact-calling-conventions/x64-win64',
    'artifact-calling-conventions/x86-fastcall',
    'artifact-calling-conventions/x86-ms-cdecl',
    'artifact-calling-conventions/x86-stdcall',
    'artifact-closures/call-prepared-closure',
    'artifact-memory-safety/guarded-u8-argument',
    'artifact-metadata/closure-size',
    'artifact-metadata/default-abi-range',
    'artifact-metadata/long-double-symbol',
    'artifact-metadata/version-number',
    'artifact-metadata/version-string',
    'artifact-registers/gp-sse-mixed-arguments',
    'artifact-scalar/cdecl-int32',
    'artifact-scalar/mixed-int-float-double',
    'artifact-scalar/return-sint16',
    'artifact-scalar/return-sint64',
    'artifact-scalar/return-uint8',
    'artifact-structs/pass-big-struct',
    'artifact-structs/pass-int-double-struct',
    'artifact-structs/pass-nested-struct',
    'artifact-structs/pass-single-entry-struct',
    'artifact-structs/pass-two-byte-struct',
    'artifact-structs/return-big-struct',
    'artifact-structs/return-int-double-struct',
    'artifact-structs/return-nested-struct',
    'artifact-structs/return-single-entry-struct',
    'artifact-structs/return-two-byte-struct',
    'artifact-varargs/prep-cif-var-double-sum',
    'artifact-varargs/prep-cif-var-int-sum',
];
$expectedIds = [
    'artifact-metadata-via-php/closure-size',
    'artifact-metadata-via-php/default-abi',
    'artifact-metadata-via-php/version-number',
    'artifact-metadata-via-php/version-string',
    'artifact-self-exe/output-present',
    'artifact-self-via-php/dll-self-test-exit',
    'php-ffi-callbacks/php-closure-to-c-callback',
    'php-ffi-calling-conventions/winapi-get-current-process-id',
    'php-ffi-calls/mixed-scalar-call',
    'php-ffi-calls/scalar-add',
    'php-ffi-memory/array-access-and-size',
    'php-ffi-memory/write-and-read-buffer',
    'php-ffi-structs/pass-nested-struct',
    'php-ffi-structs/pass-single-entry-struct',
    'php-ffi-structs/pass-struct-by-value',
    'php-ffi-structs/return-nested-struct',
    'php-ffi-structs/return-single-entry-struct',
    'php-ffi-structs/return-struct',
    'php-runtime/ffi-class-present',
    'php-runtime/ffi-enabled-for-cli',
    'php-runtime/ffi-extension-loaded',
    'php-runtime/load-probe-dll',
];

foreach ($probeIds as $probeId) {
    $expectedIds[] = 'dll-' . $probeId;
    $expectedIds[] = 'exe-' . $probeId;
}

foreach ($expectedIds as $expectedId) {
    $allIds[$expectedId] = true;
}

$expectedRuns = [
    '8.2-x64',
    '8.2-x86',
    '8.3-x64',
    '8.3-x86',
    '8.4-x64',
    '8.4-x86',
    '8.5-x64',
    '8.5-x86',
];

foreach ($files as $file) {
    $json = json_decode((string) file_get_contents($file), true);
    if (!is_array($json)) {
        $failures[] = "Could not parse $file";
        continue;
    }

    $key = sprintf('%s-%s', $json['php_input'] ?? 'unknown', $json['arch'] ?? 'unknown');
    $runs[$key] = $json;
    foreach (($json['results'] ?? []) as $result) {
        if (!isset($result['id'])) {
            continue;
        }
        $allIds[$result['id']] = true;
        if (empty($result['pass'])) {
            $failures[] = sprintf(
                '%s: %s failed (%s)',
                $key,
                $result['id'],
                $result['detail'] ?? ''
            );
        }
    }
}

foreach ($expectedRuns as $expectedRun) {
    if (!isset($runs[$expectedRun])) {
        $failures[] = "$expectedRun: missing result JSON";
    }
}

ksort($runs, SORT_NATURAL);
$allIds = array_keys($allIds);
sort($allIds, SORT_NATURAL);

echo "## libffi 3.5.2 PHP/Windows QA\n\n";
echo "| PHP input | Resolved PHP | Arch | Artifact | Tests | Failures |\n";
echo "| --- | --- | --- | --- | ---: | ---: |\n";

foreach ($runs as $run) {
    $results = $run['results'] ?? [];
    $failed = array_filter($results, static fn(array $result): bool => empty($result['pass']));
    printf(
        "| %s | %s | %s | `%s` | %d | %d |\n",
        $run['php_input'] ?? '',
        $run['php_version'] ?? '',
        $run['arch'] ?? '',
        $run['artifact'] ?? '',
        count($results),
        count($failed)
    );
}

echo "\n## Comparison Matrix\n\n";
echo "| Test | " . implode(' | ', array_keys($runs)) . " |\n";
echo "| --- | " . implode(' | ', array_fill(0, count($runs), '---')) . " |\n";

foreach ($allIds as $id) {
    $cells = [];
    foreach ($runs as $run) {
        $match = null;
        foreach (($run['results'] ?? []) as $result) {
            if (($result['id'] ?? null) === $id) {
                $match = $result;
                break;
            }
        }
        $cells[] = $match === null ? 'MISSING' : (empty($match['pass']) ? 'FAIL' : 'PASS');
        if ($match === null) {
            $failures[] = sprintf('%s: %s missing', ($run['php_input'] ?? '?') . '-' . ($run['arch'] ?? '?'), $id);
        }
    }
    echo '| `' . $id . '` | ' . implode(' | ', $cells) . " |\n";
}

if ($failures) {
    echo "\n## Failures\n\n";
    foreach (array_unique($failures) as $failure) {
        echo "- $failure\n";
    }
    exit(1);
}

echo "\nAll matrix entries passed and every discovered test is present across the compared PHP versions.\n";
