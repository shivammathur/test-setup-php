<?php

$policies = [
    'unrestricted' => '',
    'root' => '\\',
    'root-nul' => '\\;NUL',
    'directory' => getcwd(),
    'directory-nul' => getcwd() . ';NUL',
];
$mode = $argv[1];
$resolved = realpath('NUL');
if (ini_set('open_basedir', $policies[$mode]) === false) {
    throw new RuntimeException('Could not set open_basedir');
}

$results = [];
foreach (['w', 'c'] as $access) {
    error_clear_last();
    $stream = @fopen('NUL', $access);
    $results['fopen-' . $access] = [
        'success' => is_resource($stream),
        'error' => error_get_last()['message'] ?? null,
    ];
    if (is_resource($stream)) {
        fclose($stream);
    }
}

error_clear_last();
$process = @proc_open('cmd /c ver', [
    ['pipe', 'r'], ['file', 'NUL', 'w'], ['file', 'NUL', 'w'],
], $pipes);
$results['proc_open'] = [
    'success' => is_resource($process),
    'error' => error_get_last()['message'] ?? null,
    'exit_code' => null,
];
if (is_resource($process)) {
    fclose($pipes[0]);
    $results['proc_open']['exit_code'] = proc_close($process);
}

$stream = fopen(__FILE__, 'r');
$allowedFile = is_resource($stream);
if ($allowedFile) {
    fclose($stream);
}

echo json_encode([
    'php' => PHP_VERSION,
    'zts' => (bool) PHP_ZTS,
    'bits' => PHP_INT_SIZE * 8,
    'os' => php_uname(),
    'mode' => $mode,
    'open_basedir' => ini_get('open_basedir'),
    'realpath_before_restriction' => $resolved,
    'allowed_file' => $allowedFile,
    'results' => $results,
], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
