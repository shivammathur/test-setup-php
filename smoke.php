<?php
$curl = curl_version();
$checks = [
    'runtime' => PHP_VERSION === getenv('EXPECTED_RUNTIME'),
    'architecture' => PHP_INT_SIZE === 8,
    'thread_safety' => PHP_ZTS === 0,
    'configuration' => strcasecmp((string) php_ini_loaded_file(), getenv('EXPECTED_INI')) === 0,
    'timezone' => date_default_timezone_get() === 'UTC',
    'curl' => $curl['version'] === '8.23.0',
    'brotli' => ($curl['brotli_version'] ?? '') === '1.2.1',
];
echo json_encode(['checks' => $checks, 'curl' => $curl], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;
exit(in_array(false, $checks, true) ? 1 : 0);
