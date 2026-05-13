<?php

declare(strict_types=1);

if ($argc < 2) {
    fwrite(STDERR, "Usage: php aggregate_php_artifact_results.php <results-directory>\n");
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
$expectedIds = [
    'php-ffi-callbacks/php-closure-to-c-callback',
    'php-ffi-calling-conventions/winapi-get-current-process-id',
    'php-ffi-calls/gp-sse-register-mix',
    'php-ffi-calls/int64-return',
    'php-ffi-calls/mixed-scalar-call',
    'php-ffi-calls/scalar-add',
    'php-ffi-calls/small-signed-return',
    'php-ffi-calls/small-unsigned-return',
    'php-ffi-load/plain-target-dll',
    'php-ffi-memory/array-access-and-size',
    'php-ffi-memory/write-and-read-buffer',
    'php-ffi-structs/big-struct',
    'php-ffi-structs/nested-struct',
    'php-ffi-structs/pass-struct-by-value',
    'php-ffi-structs/return-struct',
    'php-ffi-structs/single-entry-struct',
    'php-ffi-structs/small-struct',
    'php-ffi-varargs/double-sum',
    'php-ffi-varargs/int-sum',
    'php-runtime/ffi-class-present',
    'php-runtime/ffi-enabled-for-cli',
    'php-runtime/ffi-extension-loaded',
    'php-runtime/thread-safety-matches-artifact',
];

foreach ($expectedIds as $expectedId) {
    $allIds[$expectedId] = true;
}

foreach ($files as $file) {
    $json = json_decode((string) file_get_contents($file), true);
    if (!is_array($json)) {
        $failures[] = "Could not parse $file";
        continue;
    }

    $key = sprintf('%s-%s-%s', $json['php_input'] ?? 'unknown', $json['arch'] ?? 'unknown', $json['ts'] ?? 'unknown');
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

if (count($runs) !== 20) {
    $failures[] = sprintf('Expected 20 result JSON files, found %d', count($runs));
}

ksort($runs, SORT_NATURAL);
$allIds = array_keys($allIds);
sort($allIds, SORT_NATURAL);

echo "## Rebuilt PHP libffi QA\n\n";
echo "| PHP input | Resolved PHP | Arch | TS | Source run | Artifact | Tests | Failures |\n";
echo "| --- | --- | --- | --- | --- | --- | ---: | ---: |\n";

foreach ($runs as $run) {
    $results = $run['results'] ?? [];
    $failed = array_filter($results, static fn(array $result): bool => empty($result['pass']));
    printf(
        "| %s | %s | %s | %s | [%s](https://github.com/shivammathur/php-windows-builder/actions/runs/%s) | `%s` | %d | %d |\n",
        $run['php_input'] ?? '',
        $run['php_version'] ?? '',
        $run['arch'] ?? '',
        $run['ts'] ?? '',
        $run['source_run_id'] ?? '',
        $run['source_run_id'] ?? '',
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
            $failures[] = sprintf('%s: %s missing', ($run['php_input'] ?? '?') . '-' . ($run['arch'] ?? '?') . '-' . ($run['ts'] ?? '?'), $id);
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

echo "\nAll rebuilt PHP artifacts passed the PHP FFI matrix.\n";
