<?php

declare(strict_types=1);

if ($argc !== 3) {
    fwrite(STDERR, "Usage: php compare_ldap_summaries.php baseline.json new.json\n");
    exit(2);
}

function load_summary(string $file): array
{
    if (!is_file($file)) {
        throw new RuntimeException("Missing summary file: $file");
    }
    return json_decode((string)file_get_contents($file), true, 512, JSON_THROW_ON_ERROR);
}

function fail(string $message): void
{
    fwrite(STDERR, "OpenLDAP comparison failed: $message\n");
    exit(1);
}

function normalize_for_compare(mixed $value): mixed
{
    if (is_array($value)) {
        $normalized = [];
        foreach ($value as $key => $item) {
            if (in_array((string)$key, ['vendor', 'vendor_version', 'duration_ms', 'errno', 'error', 'message'], true)) {
                continue;
            }
            $normalized[(string)$key] = normalize_for_compare($item);
        }
        ksort($normalized);
        return $normalized;
    }
    return $value;
}

function same_json(mixed $left, mixed $right): bool
{
    return json_encode(normalize_for_compare($left), JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)
        === json_encode(normalize_for_compare($right), JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
}

$baseline = load_summary($argv[1]);
$new = load_summary($argv[2]);

$baselineVendor = (int)($baseline['ldap']['vendor_version'] ?? 0);
$newVendor = (int)($new['ldap']['vendor_version'] ?? 0);
if (intdiv($baselineVendor, 100) !== 206) {
    fail("baseline artifact is not OpenLDAP 2.6.x; got vendor version $baselineVendor");
}
if ($newVendor !== 20700) {
    fail("new artifact is not OpenLDAP 2.7.0; got vendor version $newVendor");
}

$removedFunctions = array_values(array_diff($baseline['functions'] ?? [], $new['functions'] ?? []));
if ($removedFunctions !== []) {
    fail('new artifact removed LDAP functions: ' . implode(', ', $removedFunctions));
}

$baselineConstants = array_keys($baseline['constants'] ?? []);
$newConstants = array_keys($new['constants'] ?? []);
$removedConstants = array_values(array_diff($baselineConstants, $newConstants));
if ($removedConstants !== []) {
    fail('new artifact removed LDAP constants: ' . implode(', ', $removedConstants));
}

$allowedConstantValueChanges = [
    'LDAP_VENDOR_VERSION',
    'LDAP_VENDOR_VERSION_MAJOR',
    'LDAP_VENDOR_VERSION_MINOR',
    'LDAP_VENDOR_VERSION_PATCH',
];
foreach ($baseline['constants'] ?? [] as $name => $value) {
    if (in_array($name, $allowedConstantValueChanges, true)) {
        continue;
    }
    if (array_key_exists($name, $new['constants'] ?? []) && $new['constants'][$name] !== $value) {
        fail("constant $name changed from " . json_encode($value) . ' to ' . json_encode($new['constants'][$name]));
    }
}

foreach ($baseline['tests'] ?? [] as $name => $test) {
    if (!isset($new['tests'][$name])) {
        fail("new artifact did not run test '$name'");
    }
    $baselineStatus = $test['status'] ?? 'unknown';
    $newStatus = $new['tests'][$name]['status'] ?? 'unknown';
    if ($baselineStatus === 'passed' && $newStatus !== 'passed') {
        fail("test '$name' regressed from passed to $newStatus");
    }
    if ($baselineStatus === 'skipped' && $newStatus === 'failed') {
        fail("test '$name' regressed from skipped to failed");
    }
    $baselineWarnings = count($test['warnings'] ?? []);
    $newWarnings = count($new['tests'][$name]['warnings'] ?? []);
    if ($baselineWarnings === 0 && $newWarnings > 0) {
        fail("test '$name' introduced warnings in the new artifact");
    }
}

$mustMatchObservationKeys = [
    'controls',
    'extended_and_sasl',
    'helpers',
    'options_and_config',
    'tls',
];
foreach ($mustMatchObservationKeys as $key) {
    if (!array_key_exists($key, $baseline['observations'] ?? [])) {
        fail("baseline summary is missing observation '$key'");
    }
    if (!array_key_exists($key, $new['observations'] ?? [])) {
        fail("new summary is missing observation '$key'");
    }
    if (!same_json($baseline['observations'][$key], $new['observations'][$key])) {
        fwrite(STDERR, "Baseline $key:\n" . json_encode(normalize_for_compare($baseline['observations'][$key]), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
        fwrite(STDERR, "New $key:\n" . json_encode(normalize_for_compare($new['observations'][$key]), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
        fail("observation '$key' changed");
    }
}

$baselineCalled = $baseline['called_functions'] ?? [];
$newCalled = $new['called_functions'] ?? [];
$notExercisedInNew = array_values(array_diff($baselineCalled, $newCalled));
if ($notExercisedInNew !== []) {
    fail('new artifact did not exercise functions covered by baseline: ' . implode(', ', $notExercisedInNew));
}

echo sprintf(
    "OpenLDAP userland comparison passed for %s %s %s: %d -> %d\n",
    $new['php_ref'] ?? 'unknown',
    $new['arch'] ?? 'unknown',
    $new['thread_safety'] ?? 'unknown',
    $baselineVendor,
    $newVendor
);
