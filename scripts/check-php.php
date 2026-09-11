<?php
$expected = getenv('EXPECTED_PHP_VERSION');
if (PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION !== $expected) {
    throw new RuntimeException('Unexpected PHP version: ' . PHP_VERSION);
}
foreach (['curl', 'openssl', 'gd', 'intl', 'zip', 'mbstring', 'Zend OPcache'] as $extension) {
    if (!extension_loaded($extension)) {
        throw new RuntimeException('Missing extension: ' . $extension);
    }
}
$image = imagecreatetruecolor(2, 2);
if ($image === false || (new Collator('en_US'))->compare('a', 'b') >= 0 || mb_strtoupper('php') !== 'PHP') {
    throw new RuntimeException('Extension smoke test failed');
}
$file = tempnam(sys_get_temp_dir(), 'setup-php-zip');
$zip = new ZipArchive();
if ($zip->open($file, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true || !$zip->addFromString('test.txt', 'ok') || !$zip->close()) {
    throw new RuntimeException('ZIP write failed');
}
unlink($file);
if (ini_get('memory_limit') !== '256M' || ini_get('post_max_size') !== '64M') {
    throw new RuntimeException('INI settings were not applied');
}
$handle = curl_init();
if ($handle === false || openssl_digest('test', 'sha256') === false) {
    throw new RuntimeException('cURL/OpenSSL smoke test failed');
}
echo json_encode([
    'version' => PHP_VERSION, 'binary' => PHP_BINARY, 'architecture' => php_uname('m'),
    'extensions' => get_loaded_extensions(), 'curl' => curl_version(),
    'openssl' => OPENSSL_VERSION_TEXT, 'jit_buffer_size' => ini_get('opcache.jit_buffer_size'),
    'memory_limit' => ini_get('memory_limit'), 'post_max_size' => ini_get('post_max_size'),
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
