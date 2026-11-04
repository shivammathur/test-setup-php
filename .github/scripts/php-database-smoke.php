<?php
foreach (['odbc', 'pdo_odbc', 'mysqli', 'pdo_mysql', 'pgsql', 'pdo_pgsql'] as $extension) {
    if (!extension_loaded($extension)) {
        throw new RuntimeException("Missing built extension $extension");
    }
}
if (PHP_INT_SIZE !== (getenv('PLATFORM') === 'x64' ? 8 : 4)) {
    throw new RuntimeException('Built PHP architecture does not match the CI job');
}
$odbc = odbc_connect(getenv('ODBC_TEST_DSN'), getenv('ODBC_TEST_USER'), getenv('ODBC_TEST_PASS'));
if (!$odbc) {
    throw new RuntimeException(odbc_errormsg());
}
foreach ([
    'CREATE TABLE php_location_odbc (id int NOT NULL)',
    'INSERT INTO php_location_odbc VALUES (42)',
] as $query) {
    if (!odbc_exec($odbc, $query)) {
        throw new RuntimeException(odbc_errormsg($odbc));
    }
}
$result = odbc_exec($odbc, 'SELECT id FROM php_location_odbc');
if (!odbc_fetch_row($result) || (int) odbc_result($result, 1) !== 42) {
    throw new RuntimeException('ODBC read-back failed');
}
odbc_free_result($result);
odbc_exec($odbc, 'DROP TABLE php_location_odbc');
odbc_close($odbc);
echo "PASS ODBC create/insert/select/drop\n";
$pdo = new PDO(getenv('PDOTEST_DSN'), getenv('PDOTEST_USER'), getenv('PDOTEST_PASS'), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$pdo->exec('CREATE TABLE php_location_pdo (id int NOT NULL)');
$pdo->exec('INSERT INTO php_location_pdo VALUES (43)');
if ((int) $pdo->query('SELECT id FROM php_location_pdo')->fetchColumn() !== 43) {
    throw new RuntimeException('PDO_ODBC read-back failed');
}
$pdo->exec('DROP TABLE php_location_pdo');
echo "PASS PDO_ODBC create/insert/select/drop\n";
$mysql = new mysqli('127.0.0.1', 'root', 'Password12!', 'test', 3306);
if ((int) $mysql->query('SELECT 1')->fetch_row()[0] !== 1) {
    throw new RuntimeException('MySQLi connection failed');
}
$mysql->close();
$pdoMysql = new PDO('mysql:host=127.0.0.1;port=3306;dbname=test', 'root', 'Password12!');
if ((int) $pdoMysql->query('SELECT 1')->fetchColumn() !== 1) {
    throw new RuntimeException('PDO_MYSQL connection failed');
}
echo "PASS MySQLi and PDO_MYSQL\n";
$pgsql = pg_connect('host=127.0.0.1 port=5432 dbname=test user=postgres password=Password12!');
if ((int) pg_fetch_result(pg_query($pgsql, 'SELECT 1'), 0, 0) !== 1) {
    throw new RuntimeException('PostgreSQL connection failed');
}
pg_close($pgsql);
$pdoPgsql = new PDO('pgsql:host=127.0.0.1;port=5432;dbname=test', 'postgres', 'Password12!');
if ((int) $pdoPgsql->query('SELECT 1')->fetchColumn() !== 1) {
    throw new RuntimeException('PDO_PGSQL connection failed');
}
echo "PASS PostgreSQL and PDO_PGSQL\n";
echo PHP_VERSION, ' ', PHP_INT_SIZE * 8, '-bit ', PHP_ZTS ? 'ZTS' : 'NTS', "\n";
