<?php

declare(strict_types=1);

use Dotenv\Dotenv;

require dirname(__DIR__) . '/vendor/autoload.php';

$root = dirname(__DIR__);

if (is_file($root . '/.env')) {
    Dotenv::createImmutable($root)->safeLoad();
}

$host = getenv('DB_HOST') ?: '127.0.0.1';
$port = getenv('DB_PORT') ?: '3306';
$name = getenv('DB_NAME') ?: 'phalcon';
$user = getenv('DB_USERNAME') ?: 'root';
$password = getenv('DB_PASSWORD') ?: 'password';

$dsn = sprintf('mysql:host=%s;port=%s;dbname=%s', $host, $port, $name);

try {
    $pdo = new PDO($dsn, $user, $password, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
    $count = (int) $pdo->query('SELECT COUNT(*) FROM entries')->fetchColumn();
} catch (Throwable $exception) {
    http_response_code(500);
    header('Content-Type: text/plain');
    echo 'Database error: ' . $exception->getMessage();
    exit(1);
}

header('Content-Type: text/plain');
echo 'Phalcon MySQL ' . \Phalcon\Version::get() . PHP_EOL;
echo 'rows: ' . $count . PHP_EOL;
