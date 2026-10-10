<?php
declare(strict_types=1);

$package = json_decode(file_get_contents('evidence/package.json'), true, flags: JSON_THROW_ON_ERROR);
$runtimeFiles = glob('evidence/runtime-*.json');
if ($runtimeFiles === []) {
    throw new RuntimeException('No PHPStan analysis runtime evidence was recorded');
}
$loaded = 0;
foreach ($runtimeFiles as $file) {
    $runtime = json_decode(file_get_contents($file), true, flags: JSON_THROW_ON_ERROR);
    if ($runtime['turbo_loaded'] && $runtime['turbo_active'] && $runtime['turbo_version'] === $package['turbo_version']) {
        $loaded++;
    }
}
if (($loaded > 0) !== $package['turbo_expected']) {
    throw new RuntimeException('PHPStan automatic Turbo activation did not match the expected runtime support');
}
$diagnose = file_get_contents('evidence/diagnose.txt');
$expectedStatus = $package['turbo_expected'] ? 'Turbo extension: enabled' : 'Turbo extension: not loaded';
if (!str_contains($diagnose, $expectedStatus)) {
    throw new RuntimeException('PHPStan diagnosis did not report expected Turbo status');
}
if (!str_contains(file_get_contents('evidence/analysis.txt'), '[OK] No errors')) {
    throw new RuntimeException('PHPStan analysis did not succeed');
}
$result = $package['turbo_expected']
    ? "PASS: PHPStan analysis succeeded; Turbo loaded and active in $loaded process(es)."
    : 'PASS: PHPStan analysis succeeded; Turbo unavailable in the upstream package for this runtime.';
echo $result, "\n";
file_put_contents(getenv('GITHUB_STEP_SUMMARY'), $result . "\n", FILE_APPEND);
