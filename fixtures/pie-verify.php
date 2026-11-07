<?php
$extension = $argv[1];
$expected = $argv[2];
if (!extension_loaded($extension) || phpversion($extension) !== $expected) {
    throw new RuntimeException('Extension missing or wrong version: ' . $extension);
}
if ($extension === 'fastjson') {
    $data = ['hello' => 'world', 'values' => [1, 2, 3], 'unicode' => '✓'];
    if (fastjson_decode(fastjson_encode($data), true) !== $data) {
        throw new RuntimeException('FastJSON round trip failed');
    }
    fastjson_decode('{invalid');
    if (fastjson_last_error() === 0) { throw new RuntimeException('FastJSON accepted invalid JSON'); }
}
$binary = ini_get('extension_dir') . DIRECTORY_SEPARATOR . (PHP_OS_FAMILY === 'Windows' ? 'php_' . $extension . '.dll' : $extension . '.so');
$report = ['php' => PHP_VERSION, 'arch' => php_uname('m'), 'zts' => PHP_ZTS, 'extension' => $extension, 'version' => phpversion($extension), 'binary' => $binary, 'sha256' => hash_file('sha256', $binary), 'functionalCheck' => true];
file_put_contents('artifacts/pie-' . $extension . '.json', json_encode($report, JSON_PRETTY_PRINT));
copy($binary, 'artifacts/pie-' . basename($binary));
echo json_encode($report, JSON_PRETTY_PRINT), PHP_EOL;
