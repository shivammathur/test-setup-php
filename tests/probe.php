<?php

if (PHP_OS_FAMILY !== 'Windows') {
    throw new RuntimeException('Windows required');
}

$root = $argv[1];
$names = json_decode(file_get_contents($argv[2]), true, 512, JSON_THROW_ON_ERROR);
$marker = 'php-persisted-content';
$rows = [];
foreach ($names as $i => $name) {
    $dir = $root . DIRECTORY_SEPARATOR . $i;
    mkdir($dir, 0777, true);
    $path = $dir . DIRECTORY_SEPARATOR . $name;
    $warnings = [];
    set_error_handler(static function ($level, $message) use (&$warnings) {
        $warnings[] = $message;
        return true;
    });
    $row = ['name' => $name, 'path' => $path, 'kind' => 'failed'];
    $handle = fopen($path, 'w+b');
    if ($handle !== false) {
        $stat = fstat($handle);
        $type = $stat === false ? 0 : ($stat['mode'] & 0170000);
        $row['kind'] = match ($type) {
            0100000 => 'disk',
            0020000 => 'character',
            default => 'unknown',
        };
        $row['mode'] = $stat === false ? null : decoct($stat['mode']);
        $row['written'] = fwrite($handle, $marker);
        if ($row['kind'] === 'disk') {
            rewind($handle);
            $row['read_back'] = fread($handle, strlen($marker));
        }
        fclose($handle);
        if ($row['kind'] === 'disk') {
            $row['persisted'] = file_get_contents($path);
        }
    }
    clearstatcache();
    $row['file_exists'] = file_exists($path);
    $row['entries'] = array_values(array_diff(scandir($dir), ['.', '..']));
    restore_error_handler();
    $row['warnings'] = $warnings;
    $rows[] = $row;
}

echo json_encode([
    'version' => PHP_VERSION,
    'zts' => PHP_ZTS,
    'int_size' => PHP_INT_SIZE,
    'binary' => PHP_BINARY,
    'os' => php_uname(),
    'marker' => $marker,
    'rows' => $rows,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);

