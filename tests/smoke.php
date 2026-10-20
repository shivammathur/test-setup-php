<?php
function check($condition, $message) {
    if (!$condition) { fwrite(STDERR, $message . "\n"); exit(1); }
}
check(PHP_VERSION === getenv('EXPECTED_PHP_VERSION'), 'Wrong PHP version');
check((int) PHP_ZTS === (int) getenv('EXPECTED_PHP_ZTS'), 'Wrong thread safety');
ob_start(); phpinfo(INFO_GENERAL); $info = ob_get_clean();
check(preg_match('/PHP Extension Build => .*,' . preg_quote(getenv('EXPECTED_PHP_COMPILER'), '/') . '\b/i', $info) === 1, 'Wrong compiler ABI');
foreach (explode(',', getenv('EXPECTED_PHP_MODULES')) as $module) {
    check(extension_loaded($module), 'Missing module: ' . $module);
}
$db = new PDO('sqlite::memory:');
check((int) $db->query('SELECT 42')->fetchColumn() === 42, 'SQLite query failed');
check(gzdecode(gzencode('php-legacy')) === 'php-legacy', 'zlib round trip failed');
check((string) simplexml_load_string('<root>ok</root>') === 'ok', 'XML parse failed');
check(Normalizer::normalize("e\xcc\x81") === "\xc3\xa9", 'ICU normalization failed');
$key = str_repeat('k', 16);
$iv = str_repeat('i', 16);
$encrypted = openssl_encrypt('php-legacy', 'AES-128-CBC', $key, 0, $iv);
check(openssl_decrypt($encrypted, 'AES-128-CBC', $key, 0, $iv) === 'php-legacy', 'OpenSSL round trip failed');
$image = imagecreatetruecolor(2, 2);
ob_start(); imagepng($image); $png = ob_get_clean();
check(substr($png, 1, 3) === 'PNG', 'GD PNG creation failed');
$zipPath = tempnam(sys_get_temp_dir(), 'phpzip');
unlink($zipPath);
$zip = new ZipArchive();
check($zip->open($zipPath, ZipArchive::CREATE) === true, 'ZIP creation failed');
$zip->addFromString('test.txt', 'php-legacy'); $zip->close();
check($zip->open($zipPath) === true && $zip->getFromName('test.txt') === 'php-legacy', 'ZIP round trip failed');
$zip->close(); unlink($zipPath);
check(function_exists('opcache_get_status') && opcache_get_status(false) !== false, 'OPcache failed');
echo json_encode(array('version' => PHP_VERSION, 'compiler' => getenv('EXPECTED_PHP_COMPILER'), 'zts' => PHP_ZTS, 'curl' => curl_version(), 'openssl' => OPENSSL_VERSION_TEXT, 'icu' => INTL_ICU_VERSION, 'modules' => get_loaded_extensions()), JSON_PRETTY_PRINT), "\n";
echo "Legacy PHP smoke tests passed\n";
