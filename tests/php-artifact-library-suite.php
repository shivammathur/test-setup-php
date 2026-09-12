<?php
declare(strict_types=1);

final class SuiteFailure extends RuntimeException
{
}

final class TestSuite
{
    /** @var array<int, array{name: string, callback: callable}> */
    private array $tests = [];

    /** @var array<int, array{name: string, time: float, failure: ?string}> */
    private array $results = [];

    public function add(string $name, callable $callback): void
    {
        $this->tests[] = ['name' => $name, 'callback' => $callback];
    }

    public function run(?string $junitPath): int
    {
        $started = microtime(true);
        foreach ($this->tests as $test) {
            $caseStarted = microtime(true);
            $failure = null;
            echo "[ RUN  ] {$test['name']}\n";
            try {
                ($test['callback'])();
                echo "[ PASS ] {$test['name']}\n";
            } catch (Throwable $throwable) {
                $failure = get_class($throwable) . ': ' . $throwable->getMessage() . "\n" . $throwable->getTraceAsString();
                echo "[ FAIL ] {$test['name']}\n{$failure}\n";
            }
            $this->results[] = [
                'name' => $test['name'],
                'time' => microtime(true) - $caseStarted,
                'failure' => $failure,
            ];
        }

        $totalTime = microtime(true) - $started;
        if ($junitPath !== null) {
            $this->writeJunit($junitPath, $totalTime);
        }

        $failures = count(array_filter($this->results, static fn (array $result): bool => $result['failure'] !== null));
        echo sprintf("[ DONE ] %d tests, %d failures, %.3fs\n", count($this->results), $failures, $totalTime);

        return $failures === 0 ? 0 : 1;
    }

    private function writeJunit(string $path, float $totalTime): void
    {
        $dir = dirname($path);
        if (!is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) {
            throw new SuiteFailure("Unable to create JUnit directory: {$dir}");
        }

        $failures = count(array_filter($this->results, static fn (array $result): bool => $result['failure'] !== null));
        $xml = [];
        $xml[] = '<?xml version="1.0" encoding="UTF-8"?>';
        $xml[] = sprintf(
            '<testsuite name="php-artifact-library-suite" tests="%d" failures="%d" errors="0" skipped="0" time="%.6f">',
            count($this->results),
            $failures,
            $totalTime
        );
        foreach ($this->results as $result) {
            $xml[] = sprintf(
                '  <testcase classname="php-artifact-library-suite" name="%s" time="%.6f">',
                xml_escape($result['name']),
                $result['time']
            );
            if ($result['failure'] !== null) {
                $xml[] = sprintf('    <failure message="%s">%s</failure>', xml_escape(first_line($result['failure'])), xml_escape($result['failure']));
            }
            $xml[] = '  </testcase>';
        }
        $xml[] = '</testsuite>';

        file_put_contents($path, implode("\n", $xml) . "\n");
    }
}

function xml_escape(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_XML1, 'UTF-8');
}

function first_line(string $value): string
{
    $line = strtok($value, "\n");
    return $line === false ? $value : $line;
}

function fail_test(string $message): never
{
    throw new SuiteFailure($message);
}

function assert_true(bool $condition, string $message): void
{
    if (!$condition) {
        fail_test($message);
    }
}

function assert_false(bool $condition, string $message): void
{
    if ($condition) {
        fail_test($message);
    }
}

function assert_same(mixed $expected, mixed $actual, string $message): void
{
    if ($expected !== $actual) {
        fail_test($message . ' Expected ' . var_export($expected, true) . ', got ' . var_export($actual, true));
    }
}

function assert_not_same(mixed $unexpected, mixed $actual, string $message): void
{
    if ($unexpected === $actual) {
        fail_test($message . ' Unexpected value ' . var_export($actual, true));
    }
}

function assert_greater_than(int|float $minimum, int|float $actual, string $message): void
{
    if ($actual <= $minimum) {
        fail_test($message . " Expected > {$minimum}, got {$actual}");
    }
}

function assert_near(float $expected, float $actual, float $delta, string $message): void
{
    if (abs($expected - $actual) > $delta) {
        fail_test($message . " Expected {$expected} +/- {$delta}, got {$actual}");
    }
}

function assert_contains_value(mixed $needle, array $haystack, string $message): void
{
    if (!in_array($needle, $haystack, true)) {
        fail_test($message . ' Missing ' . var_export($needle, true) . ' in ' . var_export($haystack, true));
    }
}

function expect_throwable(string $className, callable $callback, string $message): Throwable
{
    try {
        $callback();
    } catch (Throwable $throwable) {
        if ($throwable instanceof $className) {
            return $throwable;
        }
        fail_test($message . ' Expected ' . $className . ', got ' . get_class($throwable) . ': ' . $throwable->getMessage());
    }
    fail_test($message . ' Expected ' . $className . ', no exception was thrown');
}

/**
 * @return array{0: mixed, 1: ?string}
 */
function capture_warning(callable $callback): array
{
    $warning = null;
    set_error_handler(static function (int $severity, string $message) use (&$warning): bool {
        $warning = $message;
        return true;
    });
    try {
        $result = $callback();
    } finally {
        restore_error_handler();
    }

    return [$result, $warning];
}

function make_temp_dir(string $prefix): string
{
    $base = sys_get_temp_dir() . DIRECTORY_SEPARATOR . $prefix . '-' . getmypid() . '-' . bin2hex(random_bytes(4));
    if (!mkdir($base, 0777, true) && !is_dir($base)) {
        throw new SuiteFailure("Unable to create temp directory: {$base}");
    }
    return $base;
}

function rrmdir(string $path): void
{
    if (!is_dir($path)) {
        return;
    }
    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($iterator as $item) {
        if ($item->isDir()) {
            rmdir($item->getPathname());
        } else {
            unlink($item->getPathname());
        }
    }
    rmdir($path);
}

function parse_options(array $argv): array
{
    $options = [];
    for ($i = 1; $i < count($argv); $i++) {
        if (!str_starts_with($argv[$i], '--')) {
            continue;
        }
        $key = substr($argv[$i], 2);
        $value = true;
        if (str_contains($key, '=')) {
            [$key, $value] = explode('=', $key, 2);
        } elseif (isset($argv[$i + 1]) && !str_starts_with($argv[$i + 1], '--')) {
            $value = $argv[++$i];
        }
        $options[$key] = $value;
    }
    return $options;
}

function require_extension_loaded(string $extension): void
{
    assert_true(extension_loaded($extension), "Required extension '{$extension}' is not loaded");
}

function assert_file_signature_is_avif(string $bytes): void
{
    assert_greater_than(16, strlen($bytes), 'AVIF output is too small');
    assert_same('ftyp', substr($bytes, 4, 4), 'AVIF file type box is missing');
    $brands = substr($bytes, 8, 32);
    assert_true(str_contains($brands, 'avif') || str_contains($brands, 'avis'), 'AVIF compatible brand is missing');
}

function create_reference_image(): GdImage
{
    $image = imagecreatetruecolor(48, 32);
    imagealphablending($image, false);
    imagesavealpha($image, true);

    $transparent = imagecolorallocatealpha($image, 0, 0, 0, 127);
    imagefilledrectangle($image, 0, 0, 47, 31, $transparent);

    $red = imagecolorallocatealpha($image, 230, 20, 25, 0);
    $green = imagecolorallocatealpha($image, 20, 200, 60, 0);
    $blue = imagecolorallocatealpha($image, 35, 75, 225, 0);
    $semi = imagecolorallocatealpha($image, 250, 250, 250, 48);

    imagefilledrectangle($image, 0, 0, 15, 15, $red);
    imagefilledrectangle($image, 16, 0, 31, 15, $green);
    imagefilledrectangle($image, 32, 0, 47, 15, $blue);
    imagefilledellipse($image, 24, 24, 22, 12, $semi);

    for ($x = 0; $x < 48; $x++) {
        $color = imagecolorallocatealpha($image, ($x * 5) % 256, 120, 255 - (($x * 3) % 256), 0);
        imagesetpixel($image, $x, 16, $color);
    }

    return $image;
}

function color_at(GdImage $image, int $x, int $y): array
{
    return imagecolorsforindex($image, imagecolorat($image, $x, $y));
}

function assert_dominant_channel(GdImage $image, int $x, int $y, string $channel): void
{
    $color = color_at($image, $x, $y);
    $channels = ['red' => $color['red'], 'green' => $color['green'], 'blue' => $color['blue']];
    arsort($channels);
    $dominant = array_key_first($channels);
    assert_same($channel, $dominant, "Decoded AVIF pixel {$x},{$y} has wrong dominant channel: " . json_encode($color));
}

function test_sqlite_surface(): void
{
    require_extension_loaded('sqlite3');
    require_extension_loaded('pdo_sqlite');

    assert_true(class_exists(SQLite3::class), 'SQLite3 class is missing');
    assert_true(class_exists(PDO::class), 'PDO class is missing');
    assert_contains_value('sqlite', PDO::getAvailableDrivers(), 'PDO sqlite driver is missing');

    foreach (['SQLITE3_ASSOC', 'SQLITE3_NUM', 'SQLITE3_BOTH', 'SQLITE3_INTEGER', 'SQLITE3_FLOAT', 'SQLITE3_TEXT', 'SQLITE3_BLOB', 'SQLITE3_NULL'] as $constant) {
        assert_true(defined($constant), "{$constant} is missing");
    }

    $version = SQLite3::version();
    assert_true(isset($version['versionString'], $version['versionNumber']), 'SQLite3::version returned an incomplete version payload');
    assert_greater_than(3000000, (int) $version['versionNumber'], 'SQLite runtime version is unexpectedly old');
}

function test_sqlite3_class_api(string $tmpRoot): void
{
    $db = new SQLite3(':memory:', SQLITE3_OPEN_READWRITE | SQLITE3_OPEN_CREATE);
    $db->enableExceptions(true);
    assert_true($db->busyTimeout(250), 'SQLite3::busyTimeout failed');
    assert_true($db->exec('PRAGMA foreign_keys = ON'), 'Unable to enable foreign keys');
    assert_same(1, (int) $db->querySingle('PRAGMA foreign_keys'), 'SQLite3 PRAGMA foreign_keys did not stick');

    assert_true($db->exec('CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)'), 'Unable to create parent table');
    assert_true($db->exec('CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER NOT NULL REFERENCES parent(id), name TEXT NOT NULL, amount REAL, payload BLOB, optional_value TEXT)'), 'Unable to create items table');
    assert_true($db->exec("INSERT INTO parent(name) VALUES ('root')"), 'Unable to insert parent row');

    $blob = random_bytes(64) . "\0sqlite3-blob";
    $stmt = $db->prepare('INSERT INTO items(parent_id, name, amount, payload, optional_value) VALUES (:parent_id, :name, :amount, :payload, :optional_value)');
    assert_not_same(false, $stmt, 'SQLite3::prepare returned false');
    $unicodeName = json_decode('"unicode-\u2603"', false, 512, JSON_THROW_ON_ERROR);
    $stmt->bindValue(':parent_id', 1, SQLITE3_INTEGER);
    $stmt->bindValue(':name', $unicodeName, SQLITE3_TEXT);
    $stmt->bindValue(':amount', 12.75, SQLITE3_FLOAT);
    $stmt->bindValue(':payload', $blob, SQLITE3_BLOB);
    $stmt->bindValue(':optional_value', null, SQLITE3_NULL);
    $result = $stmt->execute();
    assert_true($result instanceof SQLite3Result, 'SQLite3Stmt::execute did not return a result object');
    $result->finalize();
    assert_greater_than(0, $db->lastInsertRowID(), 'SQLite3::lastInsertRowID did not advance');

    $name = 'bound-param';
    $amount = 21.5;
    $payload = "param\0blob";
    $optional = 'set';
    $stmt = $db->prepare('INSERT INTO items(parent_id, name, amount, payload, optional_value) VALUES (1, :name, :amount, :payload, :optional_value)');
    $stmt->bindParam(':name', $name, SQLITE3_TEXT);
    $stmt->bindParam(':amount', $amount, SQLITE3_FLOAT);
    $stmt->bindParam(':payload', $payload, SQLITE3_BLOB);
    $stmt->bindParam(':optional_value', $optional, SQLITE3_TEXT);
    $result = $stmt->execute();
    assert_true($result instanceof SQLite3Result, 'SQLite3Stmt::execute with bindParam failed');
    $result->finalize();

    assert_same(2, (int) $db->querySingle('SELECT COUNT(*) FROM items'), 'Unexpected SQLite3 row count');
    assert_same($unicodeName, $db->querySingle('SELECT name FROM items WHERE id = 1'), 'SQLite3::querySingle scalar returned the wrong value');
    $single = $db->querySingle('SELECT name, amount FROM items WHERE id = 2', true);
    assert_same('bound-param', $single['name'], 'SQLite3::querySingle associative fetch returned the wrong name');
    assert_near(21.5, (float) $single['amount'], 0.0001, 'SQLite3::querySingle associative fetch returned the wrong amount');

    $rows = $db->query('SELECT id, name, payload, optional_value FROM items ORDER BY id');
    assert_true($rows instanceof SQLite3Result, 'SQLite3::query did not return a result');
    assert_same(4, $rows->numColumns(), 'SQLite3Result::numColumns returned the wrong count');
    assert_same('name', $rows->columnName(1), 'SQLite3Result::columnName returned the wrong column name');
    $first = $rows->fetchArray(SQLITE3_ASSOC);
    assert_same($unicodeName, $first['name'], 'SQLite3Result associative fetch returned the wrong first row');
    $second = $rows->fetchArray(SQLITE3_NUM);
    assert_same('bound-param', $second[1], 'SQLite3Result numeric fetch returned the wrong second row');
    assert_false((bool) $rows->fetchArray(SQLITE3_ASSOC), 'SQLite3Result should be exhausted after two rows');
    assert_true($rows->reset(), 'SQLite3Result::reset failed');
    $again = $rows->fetchArray(SQLITE3_BOTH);
    assert_same($again[1], $again['name'], 'SQLite3Result BOTH fetch did not expose numeric and associative keys');
    $rows->finalize();

    assert_true($db->exec("UPDATE items SET optional_value = 'changed' WHERE name = 'bound-param'"), 'SQLite3 update failed');
    assert_same(1, $db->changes(), 'SQLite3::changes returned the wrong count');
    assert_same("O''Reilly", SQLite3::escapeString("O'Reilly"), 'SQLite3::escapeString did not quote single quotes');

    expect_throwable(Throwable::class, static fn () => $db->exec("INSERT INTO items(parent_id, name) VALUES (999, 'bad-parent')"), 'SQLite3 foreign key violation should fail');

    $flags = defined('SQLITE3_DETERMINISTIC') ? constant('SQLITE3_DETERMINISTIC') : 0;
    assert_true($db->createFunction('php_suffix_upper', static fn ($value): string => strtoupper((string) $value) . ':PHP', 1, $flags), 'SQLite3::createFunction failed');
    assert_same('SQLITE:PHP', $db->querySingle("SELECT php_suffix_upper('sqlite')"), 'SQLite3 scalar function returned the wrong value');

    assert_true($db->createAggregate(
        'php_join_values',
        static function ($context, $rowNumber, $value): array {
            if (!is_array($context)) {
                $context = [];
            }
            $context[] = (string) $value;
            return $context;
        },
        static fn ($context, $rowNumber): string => implode('|', $context ?? []),
        1
    ), 'SQLite3::createAggregate failed');
    assert_same('bound-param|unicode-' . json_decode('"\u2603"', false, 512, JSON_THROW_ON_ERROR), $db->querySingle('SELECT php_join_values(name) FROM (SELECT name FROM items ORDER BY name)'), 'SQLite3 aggregate function returned the wrong value');

    assert_true($db->createCollation('PHP_REVERSE', static fn (string $a, string $b): int => strcmp(strrev($a), strrev($b))), 'SQLite3::createCollation failed');
    assert_true($db->exec("CREATE TABLE words(value TEXT); INSERT INTO words(value) VALUES ('abc'), ('bba'), ('zaa')"), 'Unable to create collation test rows');
    $ordered = [];
    $result = $db->query('SELECT value FROM words ORDER BY value COLLATE PHP_REVERSE');
    while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
        $ordered[] = $row['value'];
    }
    $result->finalize();
    assert_same(['zaa', 'bba', 'abc'], $ordered, 'SQLite3 custom collation returned the wrong order');

    assert_true($db->exec('CREATE TABLE blob_io(id INTEGER PRIMARY KEY, payload BLOB NOT NULL); INSERT INTO blob_io(payload) VALUES (zeroblob(8))'), 'Unable to create blob_io row');
    $blobId = (int) $db->lastInsertRowID();
    $stream = $db->openBlob('blob_io', 'payload', $blobId, 'main', SQLITE3_OPEN_READWRITE);
    assert_true(is_resource($stream), 'SQLite3::openBlob did not return a stream');
    assert_same(8, fwrite($stream, 'ABCDEFGH'), 'SQLite3 blob stream write failed');
    fclose($stream);
    $stream = $db->openBlob('blob_io', 'payload', $blobId);
    assert_same('ABCDEFGH', stream_get_contents($stream), 'SQLite3 blob stream read returned the wrong data');
    fclose($stream);

    $backupPath = $tmpRoot . DIRECTORY_SEPARATOR . 'sqlite3-backup.db';
    $backup = new SQLite3($backupPath);
    $backup->enableExceptions(true);
    assert_true($db->backup($backup), 'SQLite3::backup failed');
    assert_same(2, (int) $backup->querySingle('SELECT COUNT(*) FROM items'), 'SQLite3 backup has the wrong row count');
    $backup->close();

    if (method_exists($db, 'serialize') && method_exists($db, 'unserialize')) {
        $serialized = $db->serialize();
        assert_greater_than(100, strlen($serialized), 'SQLite3::serialize returned too little data');
        $copy = new SQLite3(':memory:');
        $copy->enableExceptions(true);
        assert_true($copy->unserialize($serialized), 'SQLite3::unserialize failed');
        assert_same(2, (int) $copy->querySingle('SELECT COUNT(*) FROM items'), 'SQLite3 unserialized database has the wrong row count');
        $copy->close();
    }

    if (method_exists($db, 'setAuthorizer') && defined('SQLITE3_OK') && defined('SQLITE3_DENY') && defined('SQLITE3_DELETE')) {
        assert_true($db->setAuthorizer(static function (int $actionCode): int {
            return $actionCode === SQLITE3_DELETE ? SQLITE3_DENY : SQLITE3_OK;
        }), 'SQLite3::setAuthorizer failed');
        expect_throwable(Throwable::class, static fn () => $db->exec('DELETE FROM items WHERE id = 1'), 'SQLite3 authorizer should deny DELETE');
    }

    $db->close();
}

function test_pdo_sqlite_api(string $tmpRoot): void
{
    $dbPath = $tmpRoot . DIRECTORY_SEPARATOR . 'pdo-sqlite.db';
    $pdo = new PDO('sqlite:' . $dbPath, null, null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_STRINGIFY_FETCHES => false,
    ]);

    assert_contains_value('sqlite', PDO::getAvailableDrivers(), 'PDO sqlite driver is not available');
    assert_same('sqlite', $pdo->getAttribute(PDO::ATTR_DRIVER_NAME), 'PDO driver name mismatch');
    $pdo->exec('PRAGMA foreign_keys = ON');
    assert_same(1, (int) $pdo->query('PRAGMA foreign_keys')->fetchColumn(), 'PDO SQLite foreign_keys PRAGMA did not stick');

    $pdo->beginTransaction();
    $pdo->exec('CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)');
    $pdo->exec('CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER NOT NULL REFERENCES parent(id), name TEXT NOT NULL UNIQUE, qty INTEGER NOT NULL, payload BLOB)');
    $pdo->exec("INSERT INTO parent(name) VALUES ('root')");
    assert_true($pdo->inTransaction(), 'PDO transaction was not active');
    $pdo->commit();
    assert_false($pdo->inTransaction(), 'PDO transaction did not close after commit');

    $pdo->beginTransaction();
    $pdo->exec('SAVEPOINT sp_before_insert');
    $pdo->exec("INSERT INTO items(parent_id, name, qty) VALUES (1, 'rolled-back', 1)");
    $pdo->exec('ROLLBACK TO sp_before_insert');
    $pdo->exec('RELEASE sp_before_insert');
    $pdo->commit();
    assert_same(0, (int) $pdo->query('SELECT COUNT(*) FROM items')->fetchColumn(), 'SQLite savepoint rollback did not remove the row');

    $payload = "pdo\0sqlite\0lob";
    $stmt = $pdo->prepare('INSERT INTO items(parent_id, name, qty, payload) VALUES (:parent_id, :name, :qty, :payload)');
    $stmt->bindValue(':parent_id', 1, PDO::PARAM_INT);
    $stmt->bindValue(':name', 'pdo-row', PDO::PARAM_STR);
    $stmt->bindValue(':qty', 7, PDO::PARAM_INT);
    $stmt->bindValue(':payload', $payload, PDO::PARAM_LOB);
    assert_true($stmt->execute(), 'PDO named prepared insert failed');
    $insertId = (int) $pdo->lastInsertId();
    assert_greater_than(0, $insertId, 'PDO::lastInsertId did not advance');

    $qty = 11;
    $name = 'pdo-param-row';
    $stream = fopen('php://temp', 'r+b');
    fwrite($stream, 'stream-lob');
    rewind($stream);
    $stmt = $pdo->prepare('INSERT INTO items(parent_id, name, qty, payload) VALUES (1, ?, ?, ?)');
    $stmt->bindParam(1, $name, PDO::PARAM_STR);
    $stmt->bindParam(2, $qty, PDO::PARAM_INT);
    $stmt->bindValue(3, $stream, PDO::PARAM_LOB);
    assert_true($stmt->execute(), 'PDO positional prepared insert failed');
    if (is_resource($stream)) {
        fclose($stream);
    }

    $stmt = $pdo->prepare('SELECT name FROM items WHERE qty > ? AND name LIKE ? ORDER BY id');
    assert_true($stmt->execute([5, 'pdo%']), 'PDO positional prepared select failed');
    assert_same('pdo-row', $stmt->fetchColumn(), 'PDO::fetchColumn returned the wrong first row');

    $stmt = $pdo->query('SELECT id, name, qty, payload FROM items ORDER BY id');
    assert_same(4, $stmt->columnCount(), 'PDOStatement::columnCount returned the wrong count');
    $meta = $stmt->getColumnMeta(1);
    assert_same('name', $meta['name'] ?? null, 'PDOStatement::getColumnMeta returned the wrong name');
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);
    assert_same(2, count($rows), 'PDO::fetchAll returned the wrong row count');
    assert_same($payload, $rows[0]['payload'], 'PDO LOB payload did not round-trip');

    expect_throwable(PDOException::class, static fn () => $pdo->exec("INSERT INTO items(parent_id, name, qty) VALUES (999, 'bad-parent', 1)"), 'PDO foreign key violation should throw');
    expect_throwable(PDOException::class, static fn () => $pdo->exec("INSERT INTO items(parent_id, name, qty) VALUES (1, 'pdo-row', 1)"), 'PDO unique constraint violation should throw');

    $attachPath = $tmpRoot . DIRECTORY_SEPARATOR . 'pdo-attach.db';
    $pdo->exec('ATTACH DATABASE ' . $pdo->quote($attachPath) . ' AS aux');
    $pdo->exec('CREATE TABLE aux.extra(value TEXT NOT NULL)');
    $pdo->exec("INSERT INTO aux.extra(value) VALUES ('attached')");
    assert_same('attached', $pdo->query('SELECT value FROM aux.extra')->fetchColumn(), 'PDO attached database read failed');
    $pdo->exec('DETACH DATABASE aux');

    if (class_exists('Pdo\\Sqlite')) {
        $modernPath = $tmpRoot . DIRECTORY_SEPARATOR . 'pdo-modern-sqlite.db';
        $sqlite = new Pdo\Sqlite('sqlite:' . $modernPath);
        $sqlite->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $sqlite->exec('CREATE TABLE items(name TEXT NOT NULL)');
        $sqlite->exec("INSERT INTO items(name) VALUES ('pdo-row'), ('pdo-param-row')");
        assert_true(method_exists($sqlite, 'createFunction'), 'Pdo\\Sqlite::createFunction is missing');
        assert_true($sqlite->createFunction('php_slug', static fn ($value): string => strtolower(str_replace(' ', '-', (string) $value)), 1), 'Pdo\\Sqlite::createFunction failed');
        assert_same('hello-sqlite', $sqlite->query("SELECT php_slug('Hello SQLite')")->fetchColumn(), 'Pdo\\Sqlite scalar function returned the wrong value');
        assert_true(method_exists($sqlite, 'createAggregate'), 'Pdo\\Sqlite::createAggregate is missing');
        assert_true($sqlite->createAggregate(
            'php_sum_lengths',
            static function ($context, $rowNumber, $value): int {
                $context = (int) ($context ?? 0) + strlen((string) $value);
                return $context;
            },
            static fn ($context, $rowNumber): int => (int) $context,
            1
        ), 'Pdo\\Sqlite::createAggregate failed');
        assert_same(20, (int) $sqlite->query('SELECT php_sum_lengths(name) FROM items')->fetchColumn(), 'Pdo\\Sqlite aggregate returned the wrong value');
        assert_true(method_exists($sqlite, 'createCollation'), 'Pdo\\Sqlite::createCollation is missing');
        assert_true($sqlite->createCollation('PHP_LEN', static fn (string $a, string $b): int => strlen($a) <=> strlen($b) ?: strcmp($a, $b)), 'Pdo\\Sqlite::createCollation failed');
        $ordered = $sqlite->query('SELECT name FROM items ORDER BY name COLLATE PHP_LEN')->fetchAll(PDO::FETCH_COLUMN);
        assert_same(['pdo-row', 'pdo-param-row'], $ordered, 'Pdo\\Sqlite collation returned the wrong order');
    } else {
        assert_true(method_exists($pdo, 'sqliteCreateFunction'), 'PDO::sqliteCreateFunction is missing');
        assert_true($pdo->sqliteCreateFunction('php_slug', static fn ($value): string => strtolower(str_replace(' ', '-', (string) $value)), 1), 'PDO::sqliteCreateFunction failed');
        assert_same('hello-sqlite', $pdo->query("SELECT php_slug('Hello SQLite')")->fetchColumn(), 'PDO SQLite scalar function returned the wrong value');

        assert_true(method_exists($pdo, 'sqliteCreateAggregate'), 'PDO::sqliteCreateAggregate is missing');
        assert_true($pdo->sqliteCreateAggregate(
            'php_sum_lengths',
            static function ($context, $rowNumber, $value): int {
                $context = (int) ($context ?? 0) + strlen((string) $value);
                return $context;
            },
            static fn ($context, $rowNumber): int => (int) $context,
            1
        ), 'PDO::sqliteCreateAggregate failed');
        assert_same(20, (int) $pdo->query('SELECT php_sum_lengths(name) FROM items')->fetchColumn(), 'PDO SQLite aggregate returned the wrong value');

        assert_true(method_exists($pdo, 'sqliteCreateCollation'), 'PDO::sqliteCreateCollation is missing');
        assert_true($pdo->sqliteCreateCollation('PHP_LEN', static fn (string $a, string $b): int => strlen($a) <=> strlen($b) ?: strcmp($a, $b)), 'PDO::sqliteCreateCollation failed');
        $ordered = $pdo->query('SELECT name FROM items ORDER BY name COLLATE PHP_LEN')->fetchAll(PDO::FETCH_COLUMN);
        assert_same(['pdo-row', 'pdo-param-row'], $ordered, 'PDO SQLite collation returned the wrong order');
    }
}

function test_avif_surface(): void
{
    require_extension_loaded('gd');
    assert_true(function_exists('imageavif'), 'imageavif is missing');
    assert_true(function_exists('imagecreatefromavif'), 'imagecreatefromavif is missing');
    assert_true(defined('IMG_AVIF'), 'IMG_AVIF is missing');
    assert_true(defined('IMAGETYPE_AVIF'), 'IMAGETYPE_AVIF is missing');
    assert_true((imagetypes() & IMG_AVIF) === IMG_AVIF, 'imagetypes does not advertise IMG_AVIF');
    assert_same('image/avif', image_type_to_mime_type(IMAGETYPE_AVIF), 'AVIF MIME type mapping is wrong');
    assert_same('.avif', image_type_to_extension(IMAGETYPE_AVIF), 'AVIF extension mapping is wrong');
    $info = gd_info();
    assert_true(($info['AVIF Support'] ?? false) === true, 'gd_info does not report AVIF Support');
}

function test_avif_file_stream_and_string_roundtrip(string $tmpRoot): void
{
    $image = create_reference_image();
    assert_true(imageistruecolor($image), 'Reference image must be truecolor');
    assert_same(48, imagesx($image), 'Reference image width mismatch');
    assert_same(32, imagesy($image), 'Reference image height mismatch');

    $file = $tmpRoot . DIRECTORY_SEPARATOR . 'roundtrip.avif';
    assert_true(imageavif($image, $file, 100, 4), 'imageavif failed to write a file');
    assert_greater_than(100, filesize($file), 'AVIF file is unexpectedly small');
    assert_file_signature_is_avif(file_get_contents($file));

    $size = getimagesize($file);
    assert_same(48, $size[0], 'getimagesize width mismatch');
    assert_same(32, $size[1], 'getimagesize height mismatch');
    assert_same('image/avif', $size['mime'], 'getimagesize MIME mismatch');
    if (function_exists('exif_imagetype')) {
        assert_same(IMAGETYPE_AVIF, exif_imagetype($file), 'exif_imagetype did not identify AVIF');
    }

    $decoded = imagecreatefromavif($file);
    assert_true($decoded instanceof GdImage, 'imagecreatefromavif did not return a GdImage');
    assert_same(48, imagesx($decoded), 'Decoded AVIF width mismatch');
    assert_same(32, imagesy($decoded), 'Decoded AVIF height mismatch');
    assert_dominant_channel($decoded, 8, 8, 'red');
    assert_dominant_channel($decoded, 24, 8, 'green');
    assert_dominant_channel($decoded, 40, 8, 'blue');
    $transparent = color_at($decoded, 44, 28);
    assert_true($transparent['alpha'] >= 70, 'Decoded AVIF alpha channel was not preserved: ' . json_encode($transparent));

    ob_start();
    assert_true(imageavif($image, null, 80, 6), 'imageavif failed to write to output buffer');
    $buffer = ob_get_clean();
    assert_file_signature_is_avif($buffer);
    $bufferSize = getimagesizefromstring($buffer);
    assert_same(48, $bufferSize[0], 'getimagesizefromstring width mismatch');
    assert_same('image/avif', $bufferSize['mime'], 'getimagesizefromstring MIME mismatch');
    $fromString = imagecreatefromstring($buffer);
    assert_true($fromString instanceof GdImage, 'imagecreatefromstring did not decode AVIF output');

    $streamFile = $tmpRoot . DIRECTORY_SEPARATOR . 'stream.avif';
    $stream = fopen($streamFile, 'wb');
    assert_true(imageavif($image, $stream, -1, -1), 'imageavif failed to write to a stream');
    fclose($stream);
    assert_file_signature_is_avif(file_get_contents($streamFile));
    $streamDecoded = imagecreatefromavif($streamFile);
    assert_true($streamDecoded instanceof GdImage, 'imagecreatefromavif did not read stream output');

}

function test_avif_quality_speed_and_errors(string $tmpRoot): void
{
    $image = create_reference_image();
    foreach ([[-1, -1], [0, 10], [50, 6], [100, 0]] as [$quality, $speed]) {
        $file = $tmpRoot . DIRECTORY_SEPARATOR . "q{$quality}-s{$speed}.avif";
        assert_true(imageavif($image, $file, $quality, $speed), "imageavif failed for quality={$quality} speed={$speed}");
        assert_file_signature_is_avif(file_get_contents($file));
        $decoded = imagecreatefromavif($file);
        assert_true($decoded instanceof GdImage, "imagecreatefromavif failed for quality={$quality} speed={$speed}");
        assert_same(48, imagesx($decoded), 'Decoded quality/speed test width mismatch');
    }

    assert_imageavif_invalid_range_behavior($image, $tmpRoot, 'quality-low', -2, 6);
    assert_imageavif_invalid_range_behavior($image, $tmpRoot, 'quality-high', 101, 6);
    assert_imageavif_invalid_range_behavior($image, $tmpRoot, 'speed-low', 80, -2);
    assert_imageavif_invalid_range_behavior($image, $tmpRoot, 'speed-high', 80, 11);

    $invalid = $tmpRoot . DIRECTORY_SEPARATOR . 'invalid.avif';
    file_put_contents($invalid, 'not-an-avif');
    [$result, $warning] = capture_warning(static fn () => imagecreatefromavif($invalid));
    assert_false((bool) $result, 'imagecreatefromavif should reject invalid AVIF data');
    assert_true($warning !== null, 'imagecreatefromavif should raise a warning for invalid AVIF data');

}

function assert_imageavif_invalid_range_behavior(GdImage $image, string $tmpRoot, string $label, int $quality, int $speed): void
{
    $path = $tmpRoot . DIRECTORY_SEPARATOR . "invalid-range-{$label}.avif";
    if (PHP_VERSION_ID >= 80400) {
        expect_throwable(ValueError::class, static fn () => imageavif($image, $path, $quality, $speed), "imageavif should reject {$label}");
        return;
    }

    [$result, $warning] = capture_warning(static fn () => imageavif($image, $path, $quality, $speed));
    assert_true(is_bool($result), "imageavif legacy {$label} behavior should return a boolean");
    if ($result) {
        assert_file_signature_is_avif(file_get_contents($path));
    } else {
        assert_true($warning !== null, "imageavif legacy {$label} failure should raise a warning");
    }
}

function wait_for_file(string $path, float $seconds): void
{
    $deadline = microtime(true) + $seconds;
    while (microtime(true) < $deadline) {
        if (is_file($path)) {
            return;
        }
        usleep(100000);
    }
    fail_test("Timed out waiting for file: {$path}");
}

function collect_process_output(array $pipes): array
{
    $stdout = isset($pipes[1]) && is_resource($pipes[1]) ? stream_get_contents($pipes[1]) : '';
    $stderr = isset($pipes[2]) && is_resource($pipes[2]) ? stream_get_contents($pipes[2]) : '';
    return [$stdout, $stderr];
}

function test_ldap_sasl_plain_bind(string $tmpRoot): void
{
    require_extension_loaded('ldap');
    assert_true(function_exists('ldap_connect'), 'ldap_connect is missing');
    assert_true(function_exists('ldap_sasl_bind'), 'ldap_sasl_bind is missing; LDAP was not built with SASL support');

    $portFile = $tmpRoot . DIRECTORY_SEPARATOR . 'ldap-port.json';
    $logFile = $tmpRoot . DIRECTORY_SEPARATOR . 'ldap-sasl-log.json';
    $server = __DIR__ . DIRECTORY_SEPARATOR . 'mock-ldap-sasl-server.php';
    assert_true(is_file($server), 'Mock LDAP SASL server script is missing');

    $descriptorSpec = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $process = proc_open([
        PHP_BINARY,
        '-n',
        $server,
        '--port-file',
        $portFile,
        '--log-file',
        $logFile,
    ], $descriptorSpec, $pipes, __DIR__);

    assert_true(is_resource($process), 'Unable to start mock LDAP SASL server');
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    try {
        $deadline = microtime(true) + 15.0;
        while (!is_file($portFile)) {
            $status = proc_get_status($process);
            if (!$status['running']) {
                [$stdout, $stderr] = collect_process_output($pipes);
                $exitCode = proc_close($process);
                $process = null;
                fail_test("Mock LDAP SASL server exited before publishing a port with {$exitCode}. stdout={$stdout} stderr={$stderr}");
            }
            if (microtime(true) >= $deadline) {
                [$stdout, $stderr] = collect_process_output($pipes);
                fail_test("Timed out waiting for mock LDAP SASL server port. stdout={$stdout} stderr={$stderr}");
            }
            usleep(100000);
        }
        $portInfo = json_decode(file_get_contents($portFile), true, 512, JSON_THROW_ON_ERROR);
        $port = (int) ($portInfo['port'] ?? 0);
        assert_greater_than(0, $port, 'Mock LDAP SASL server did not publish a valid port');

        $ldap = ldap_connect('ldap://127.0.0.1:' . $port);
        assert_true($ldap !== false, 'ldap_connect returned false');
        assert_true(ldap_set_option($ldap, LDAP_OPT_PROTOCOL_VERSION, 3), 'Unable to set LDAP protocol version');
        assert_true(ldap_set_option($ldap, LDAP_OPT_REFERRALS, 0), 'Unable to disable LDAP referrals');
        if (defined('LDAP_OPT_NETWORK_TIMEOUT')) {
            ldap_set_option($ldap, LDAP_OPT_NETWORK_TIMEOUT, 5);
        }

        $authcid = 'php-artifact-user';
        $authzid = 'php-artifact-authz';
        $password = 'correct horse battery staple';
        $bound = @ldap_sasl_bind($ldap, null, $password, 'PLAIN', null, $authcid, $authzid, 'none,minssf=0,maxssf=0');
        if (!$bound) {
            $error = function_exists('ldap_error') ? ldap_error($ldap) : 'unknown';
            $errno = function_exists('ldap_errno') ? ldap_errno($ldap) : -1;
            fail_test("ldap_sasl_bind failed with {$errno}: {$error}");
        }
        ldap_unbind($ldap);

        $deadline = microtime(true) + 10.0;
        $serverExitCode = null;
        do {
            $status = proc_get_status($process);
            if (!$status['running']) {
                $serverExitCode = isset($status['exitcode']) && $status['exitcode'] >= 0 ? (int) $status['exitcode'] : null;
                break;
            }
            usleep(100000);
        } while (microtime(true) < $deadline);

        $status = proc_get_status($process);
        if ($status['running']) {
            proc_terminate($process);
            fail_test('Mock LDAP SASL server did not exit after bind');
        }

        [$stdout, $stderr] = collect_process_output($pipes);
        $closeCode = proc_close($process);
        $exitCode = $serverExitCode ?? $closeCode;
        $process = null;
        assert_same(0, $exitCode, "Mock LDAP SASL server failed. stdout={$stdout} stderr={$stderr}");

        $event = json_decode(file_get_contents($logFile), true, 512, JSON_THROW_ON_ERROR);
        assert_same(3, (int) $event['version'], 'LDAP bind request used the wrong protocol version');
        assert_same('PLAIN', $event['mechanism'], 'LDAP SASL mechanism mismatch');
        assert_same($authzid, $event['plain_parts'][0] ?? null, 'SASL PLAIN authzid mismatch');
        assert_same($authcid, $event['plain_parts'][1] ?? null, 'SASL PLAIN authcid mismatch');
        assert_same($password, $event['plain_parts'][2] ?? null, 'SASL PLAIN password mismatch');
        assert_true(($event['unbind_seen'] ?? false) === true, 'LDAP client did not send an unbind request');
    } finally {
        if (isset($process) && is_resource($process)) {
            $status = proc_get_status($process);
            if ($status['running']) {
                proc_terminate($process);
            }
            proc_close($process);
        }
    }
}

$options = parse_options($argv);
$junitPath = isset($options['junit']) && is_string($options['junit']) ? $options['junit'] : null;
$runId = isset($options['run-id']) && is_string($options['run-id']) ? $options['run-id'] : 'unknown';
$build = isset($options['build']) && is_string($options['build']) ? $options['build'] : basename(PHP_BINARY);

$tmpRoot = make_temp_dir('php-artifact-library-suite');
register_shutdown_function(static fn () => rrmdir($tmpRoot));

echo "PHP binary: " . PHP_BINARY . "\n";
echo "PHP version: " . PHP_VERSION . "\n";
echo "Run id: {$runId}\n";
echo "Build: {$build}\n";
echo "Temp: {$tmpRoot}\n";

$suite = new TestSuite();
$suite->add('sqlite extension surface', 'test_sqlite_surface');
$suite->add('SQLite3 class API coverage', static fn () => test_sqlite3_class_api($tmpRoot));
$suite->add('PDO SQLite API coverage', static fn () => test_pdo_sqlite_api($tmpRoot));
$suite->add('AVIF/GD extension surface', 'test_avif_surface');
$suite->add('AVIF file, stream, and string roundtrip', static fn () => test_avif_file_stream_and_string_roundtrip($tmpRoot));
$suite->add('AVIF encoder bounds and invalid input handling', static fn () => test_avif_quality_speed_and_errors($tmpRoot));
$suite->add('LDAP SASL PLAIN bind via libsasl', static fn () => test_ldap_sasl_plain_bind($tmpRoot));

exit($suite->run($junitPath));
