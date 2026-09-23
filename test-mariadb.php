<?php
$root = realpath($argv[1]);
$version = $argv[2];
$hashes = [
    '10.11.18' => '1e36bb0834718e56fd53e150978b55429e5da921a97c07c16b41086c0c61099c',
    '10.11.19' => '398ea30e5036010bbebe01d2b1804280424dcc2626e36d8e95155c04d25a0490',
];
function check($condition, $message) {
    if (!$condition) throw new RuntimeException($message);
}
set_error_handler(function ($severity, $message, $file, $line) {
    throw new ErrorException($message, 0, $severity, $file, $line);
});
putenv('PHP_SDK_ROOT_PATH=' . $root);
require $root . '/lib/php/autoload.php';
$config = new SDK\Build\PGO\Config(SDK\Build\PGO\Config::MODE_INIT);
check($config->getSectionItem('mariadb', 'pkg_url') === 'https://archive.mariadb.org/mariadb-10.11.19/winx64-packages/mariadb-10.11.19-winx64.zip', 'Unexpected candidate URL');
if ($version === '10.11.18') {
    $config->setSectionItem('mariadb', 'pkg_url', 'https://archive.mariadb.org/mariadb-10.11.18/winx64-packages/mariadb-10.11.18-winx64.zip');
}
foreach ([$config->getPkgCacheDir(), $config->getSrvDir()] as $path) mkdir($path, 0777, true);
$server = new SDK\Build\PGO\Server\MariaDB($config);
$workman = new SDK\Build\PGO\Tool\PackageWorkman($config);
$server->prepareInit($workman);
check(hash_file('sha256', $config->getPkgCacheDir() . '/mariadb.zip') === $hashes[$version], 'Upstream SHA-256 mismatch');
$base = $config->getSrvDir('mariadb');
foreach (['mariadb-install-db.exe', 'mysqld.exe', 'mysql.exe', 'mysqladmin.exe'] as $name) {
    $bytes = file_get_contents($base . '/bin/' . $name);
    check(substr($bytes, 0, 2) === 'MZ', "$name missing DOS header");
    $offset = unpack('Voffset', substr($bytes, 60, 4))['offset'];
    check(substr($bytes, $offset, 4) === "PE\0\0", "$name missing PE signature");
    check(unpack('vmachine', substr($bytes, $offset + 4, 2))['machine'] === 0x8664, "$name architecture changed");
    check(unpack('vmagic', substr($bytes, $offset + 24, 2))['magic'] === 0x20b, "$name is not PE32+");
    echo "$name: PE32+ x64\n";
}
echo "ZIP SHA-256 matches upstream; bundled PHP " . PHP_VERSION . "\n";
$server->init();
check(is_dir($base . '/data/mysql'), 'SDK initialization did not create system tables');
$started = false;
try {
    $server->up();
    $started = true;
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $db = new mysqli('127.0.0.1', 'root', '', '', 3307);
    $db->set_charset('utf8mb4');
    $actual = $db->query('SELECT VERSION()')->fetch_row()[0];
    check(strpos($actual, $version . '-MariaDB') === 0, 'Wrong server version: ' . $actual);
    $server->query('CREATE DATABASE sdk_pgo_smoke CHARACTER SET utf8mb4');
    $server->query('CREATE TABLE sample (id INT PRIMARY KEY, value VARCHAR(100)) ENGINE=InnoDB', 'sdk_pgo_smoke');
    $sql = $root . '/pgo/work/import.sql';
    file_put_contents($sql, "INSERT INTO sample VALUES (1, _utf8mb4 0x50474F20E29C93);\n");
    $server->import($sql, 'sdk_pgo_smoke');
    $row = $db->query('SELECT id, HEX(value) FROM sdk_pgo_smoke.sample')->fetch_row();
    check((int)$row[0] === 1 && $row[1] === '50474F20E29C93', 'SDK query/import roundtrip failed');
    $db->close();
    $server->down();
    $started = false;
    sleep(1);
    $stopped = false;
    try { $unexpected = new mysqli('127.0.0.1', 'root', '', '', 3307); $unexpected->close(); }
    catch (mysqli_sql_exception $e) { $stopped = true; }
    check($stopped, 'SDK shutdown left MariaDB running');
    echo "PASS: $actual; SDK download, initialize, start, query, import, Unicode and shutdown\n";
} finally {
    if ($started) $server->down(true);
}
