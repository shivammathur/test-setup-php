<?php
function check(bool $condition, string $message): void {
    if (!$condition) {
        fwrite(STDERR, $message . PHP_EOL);
        exit(1);
    }
}
check(PHP_MAJOR_VERSION === 8 && PHP_MINOR_VERSION === 7, 'Expected PHP 8.7, got ' . PHP_VERSION);
check((bool) PHP_ZTS === (getenv('phpts') === 'ts'), 'Unexpected thread safety');
$cacheDir = realpath(getenv('CACHE_DIR'));
$runtimeDir = realpath(ini_get('extension_dir'));
check($cacheDir !== false && $cacheDir === $runtimeDir, 'Cache directory does not match PHP extension_dir: ' . $cacheDir . ' / ' . $runtimeDir);
$files = [];
foreach (array_map('trim', explode(',', getenv('EXTENSIONS'))) as $extension) {
    check(extension_loaded($extension), 'Missing extension: ' . $extension);
    $filename = PHP_OS_FAMILY === 'Windows' ? 'php_' . $extension . '.dll' : $extension . '.so';
    $path = $runtimeDir . DIRECTORY_SEPARATOR . $filename;
    check(is_file($path) && filesize($path) > 0, 'Missing extension binary: ' . $path);
    $files[$filename] = hash_file('sha256', $path);
}
if (PHP_OS_FAMILY === 'Windows') {
    \pcov\start();
    check(IntlChar::ord('A') === 65, 'intl runtime check failed');
    check(mb_strtoupper('é', 'UTF-8') === 'É', 'mbstring runtime check failed');
    check(is_array(\pcov\collect()), 'PCOV coverage collection failed');
    \pcov\stop();
} else {
    $value = ['php' => PHP_VERSION, 'numbers' => [1, 2, 3], 'unicode' => 'PHP ✓'];
    check(igbinary_unserialize(igbinary_serialize($value)) === $value, 'igbinary round trip failed');
    check(msgpack_unpack(msgpack_pack($value)) === $value, 'msgpack round trip failed');
    $client = new Memcached();
    check($client->setOption(Memcached::OPT_COMPRESSION, false), 'Memcached options failed');
}
if (($argv[1] ?? '') === 'restore') {
    $expected = json_decode(file_get_contents('.e2e/manifest.json'), true, 512, JSON_THROW_ON_ERROR);
    check($expected['files'] === $files, 'Restored extension binaries changed during setup-php');
}
$result = ['php' => PHP_VERSION, 'os' => PHP_OS_FAMILY, 'architecture' => php_uname('m'), 'zts' => PHP_ZTS, 'extension_dir' => $runtimeDir, 'files' => $files];
echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;
file_put_contents('manifest.json', json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
