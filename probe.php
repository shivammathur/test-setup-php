<?php
function observe(callable $operation): array
{
    $warnings = [];
    set_error_handler(static function ($severity, $message) use (&$warnings) {
        $warnings[] = $message;
        return true;
    });
    try {
        $value = $operation();
        return ['value' => $value, 'warnings' => $warnings];
    } finally {
        restore_error_handler();
    }
}

[$script, $path, $mode, $basedir] = $argv;
$setting = $mode === 'runtime'
    ? observe(static fn() => ini_set('open_basedir', $basedir))
    : null;
clearstatcache(true);
echo json_encode([
    'version' => PHP_VERSION,
    'zts' => PHP_ZTS,
    'bits' => PHP_INT_SIZE * 8,
    'path' => $path,
    'mode' => $mode,
    'setting' => $setting,
    'open_basedir' => ini_get('open_basedir'),
    'realpath' => observe(static fn() => realpath($path)),
    'exists' => observe(static fn() => file_exists($path)),
    'read' => observe(static fn() => file_get_contents($path)),
], JSON_THROW_ON_ERROR | JSON_PRETTY_PRINT), "\n";
