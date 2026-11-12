<?php
function check(bool $condition, string $message): void {
    if (!$condition) {
        throw new RuntimeException($message);
    }
}
check(PHP_MAJOR_VERSION === 8 && PHP_MINOR_VERSION === 7, 'Wrong PHP version');
check(PHP_INT_SIZE === (getenv('PHP_ARCH') === 'x64' ? 8 : 4), 'Wrong runtime architecture');
check((bool) PHP_ZTS === (getenv('PHP_TS') === 'ts'), 'Wrong thread safety');
foreach (['sqlsrv', 'pdo_sqlsrv'] as $extension) {
    check(extension_loaded($extension), "$extension is not loaded");
    check(phpversion($extension) === '5.13.3', "$extension has the wrong version");
}
foreach (['sqlsrv_connect', 'sqlsrv_query', 'sqlsrv_fetch_array', 'sqlsrv_errors'] as $function) {
    check(function_exists($function), "$function was not registered");
}
check(in_array('sqlsrv', PDO::getAvailableDrivers(), true), 'PDO SQLSRV driver was not registered');
check(defined('PDO::SQLSRV_ATTR_ENCODING'), 'PDO SQLSRV constants were not registered');
check((bool) sqlsrv_get_config('WarningsReturnAsErrors'), 'Unexpected initial warning setting');
check(sqlsrv_configure('WarningsReturnAsErrors', false), 'Could not update warning setting');
check(!sqlsrv_get_config('WarningsReturnAsErrors'), 'Warning setting did not change');
check(sqlsrv_configure('WarningsReturnAsErrors', true), 'Could not restore warning setting');
check((bool) sqlsrv_get_config('WarningsReturnAsErrors'), 'Warning setting did not restore');
check(sqlsrv_errors() === null, 'Unexpected SQLSRV errors');
echo json_encode([
    'php' => PHP_VERSION,
    'bits' => PHP_INT_SIZE * 8,
    'zts' => PHP_ZTS,
    'sqlsrv' => phpversion('sqlsrv'),
    'pdo_sqlsrv' => phpversion('pdo_sqlsrv'),
    'pdo_drivers' => PDO::getAvailableDrivers(),
    'functions' => count(get_extension_funcs('sqlsrv')),
    'result' => 'PASS',
], JSON_PRETTY_PRINT), PHP_EOL;
