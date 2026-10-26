<?php
$curl = curl_version();
$ini = php_ini_loaded_file();
$expectedIni = getenv('EXPECTED_INI');
$checks = [
    'runtime' => PHP_VERSION === getenv('EXPECTED_RUNTIME'),
    'architecture' => PHP_INT_SIZE === 8,
    'thread_safety' => !PHP_ZTS,
    'configuration' => $ini !== false && realpath($ini) !== false
        && strcasecmp(realpath($ini), (string) realpath($expectedIni)) === 0,
    'timezone' => date_default_timezone_get() === 'UTC',
    'curl' => $curl['version'] === '8.23.0',
    'brotli' => ($curl['brotli_ver_num'] ?? 0) === 0x1002001
        && preg_replace('~^brotli/~', '', $curl['brotli_version'] ?? '') === '1.2.1'
        && ($curl['features'] & CURL_VERSION_BROTLI) !== 0,
];
echo json_encode([
    'checks' => $checks,
    'ini' => $ini,
    'expected_ini' => $expectedIni,
    'zts' => PHP_ZTS,
    'curl' => $curl,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;
exit(in_array(false, $checks, true) ? 1 : 0);
