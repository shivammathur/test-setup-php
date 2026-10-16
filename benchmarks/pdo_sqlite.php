<?php

declare(strict_types=1);

$iterations = isset($argv[1]) ? max(1, (int) $argv[1]) : 5000;
$dbFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'pgo-pdo-sqlite-' . getmypid() . '.sqlite';

@unlink($dbFile);

$pdo = new PDO('sqlite:' . $dbFile, null, null, [
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    PDO::ATTR_EMULATE_PREPARES => false,
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
]);

$pdo->exec('PRAGMA journal_mode = MEMORY');
$pdo->exec('PRAGMA synchronous = OFF');
$pdo->exec('PRAGMA temp_store = MEMORY');
$pdo->exec('CREATE TABLE items (id INTEGER PRIMARY KEY, group_id INTEGER NOT NULL, name TEXT NOT NULL, value INTEGER NOT NULL)');

$insert = $pdo->prepare('INSERT INTO items (id, group_id, name, value) VALUES (?, ?, ?, ?)');
$pdo->beginTransaction();
for ($i = 1; $i <= 2000; $i++) {
    $insert->execute([$i, $i % 64, 'item-' . $i, ($i * 17) % 100000]);
}
$pdo->commit();

$select = $pdo->prepare('SELECT id, name, value FROM items WHERE group_id = ? AND value >= ? ORDER BY value DESC LIMIT 12');
$update = $pdo->prepare('UPDATE items SET value = value + ? WHERE id = ?');
$delete = $pdo->prepare('DELETE FROM items WHERE id % 97 = ?');
$checksum = 0;

for ($i = 0; $i < $iterations; $i++) {
    $select->execute([$i % 64, ($i * 13) % 50000]);
    $rows = $select->fetchAll();

    foreach ($rows as $row) {
        $checksum ^= (int) $row['id'] + (int) $row['value'] + strlen((string) $row['name']);
        $update->execute([($i % 7) + 1, $row['id']]);
    }

    if (($i % 25) === 0) {
        $delete->execute([$i % 97]);
    }
}

unset($pdo);
@unlink($dbFile);

echo $checksum, PHP_EOL;
