<?php
function check_smoke($ok, $name) {
    if (!$ok) { throw new Exception('Smoke check failed: '.$name); }
}
foreach (array('json', 'hash', 'openssl', 'curl', 'mbstring', 'zlib', 'session', 'PDO', 'pdo_sqlite', 'sqlite3', 'zip') as $module) {
    check_smoke(extension_loaded($module), 'module '.$module);
}
$json = json_decode(json_encode(array('value' => 42)), true); check_smoke($json['value'] === 42, 'JSON round trip');
check_smoke(hash('sha256', 'abc') === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'SHA256');
check_smoke(mb_strlen('日本語', 'UTF-8') === 3, 'UTF8 multibyte');
check_smoke(gzuncompress(gzcompress('security smoke')) === 'security smoke', 'zlib');
$iv = str_repeat('a', 16); $key = str_repeat('b', 16);
$cipher = openssl_encrypt('smoke payload', 'AES-128-CBC', $key, 0, $iv);
check_smoke(openssl_decrypt($cipher, 'AES-128-CBC', $key, 0, $iv) === 'smoke payload', 'OpenSSL encryption');
check_smoke(is_array(curl_version()) && curl_init() !== false, 'curl initialization');
$db = new PDO('sqlite::memory:');
$db->exec('CREATE TABLE smoke (value INTEGER)'); $db->exec('INSERT INTO smoke VALUES (42)');
check_smoke((int)$db->query('SELECT value FROM smoke')->fetchColumn() === 42, 'PDO SQLite');
$sqlite = new SQLite3(':memory:'); check_smoke($sqlite->querySingle('SELECT 42') === 42, 'SQLite3');
$file = tempnam(sys_get_temp_dir(), 'oct-smoke-');
check_smoke(file_put_contents($file, 'artifact smoke') === 14 && file_get_contents($file) === 'artifact smoke', 'filesystem');
unlink($file);
$zip = new ZipArchive(); check_smoke($zip->open($file, ZipArchive::CREATE) === true, 'ZIP create');
$zip->addFromString('smoke.txt', 'payload'); $zip->close();
check_smoke($zip->open($file) === true && $zip->getFromName('smoke.txt') === 'payload', 'ZIP read'); $zip->close(); unlink($file);
ini_set('session.save_path', sys_get_temp_dir()); session_id('octsmoke'.getmypid());
check_smoke(session_start(), 'session start'); $_SESSION['smoke'] = 42; session_write_close();
check_smoke(session_start() && $_SESSION['smoke'] === 42, 'session persisted'); session_destroy();
$curlInfo = curl_version();
$modules = get_loaded_extensions(); sort($modules);
echo json_encode(array('status'=>'passed', 'version'=>PHP_VERSION, 'zts'=>(bool)PHP_ZTS, 'debug'=>(bool)PHP_DEBUG, 'int_size'=>PHP_INT_SIZE, 'sapi'=>PHP_SAPI, 'os'=>PHP_OS, 'modules'=>$modules, 'openssl'=>OPENSSL_VERSION_TEXT, 'curl'=>$curlInfo['version'])), "\n";
