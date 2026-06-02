<?php
error_reporting(E_ALL);
ini_set('display_errors', '1');

$expectedZts = isset($argv[1]) ? (int) $argv[1] : null;
$failures = [];

function record_result(string $name, bool $ok, $detail = null): void
{
    global $failures;

    echo ($ok ? 'PASS' : 'FAIL') . ' ' . $name;
    if ($detail !== null) {
        echo ' :: ' . str_replace(PHP_EOL, '\n', (string) $detail);
    }
    echo PHP_EOL;

    if (!$ok) {
        $failures[] = $name;
    }
}

function expect_false(string $name, callable $callback): void
{
    $result = $callback();
    record_result($name, $result === false, var_export($result, true));
}

printf(
    "PHP_VERSION=%s PHP_ZTS=%d PHP_OS_FAMILY=%s PHP_BINARY=%s\n",
    PHP_VERSION,
    PHP_ZTS,
    PHP_OS_FAMILY,
    PHP_BINARY
);

record_result('expected PHP_ZTS', $expectedZts === null || PHP_ZTS === $expectedZts, PHP_ZTS);
record_result('Windows runtime', PHP_OS_FAMILY === 'Windows', PHP_OS_FAMILY);

$base = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'php-device-' . bin2hex(random_bytes(4));
if (!mkdir($base)) {
    fwrite(STDERR, "Unable to create temp directory: $base\n");
    exit(1);
}

try {
    $nul = $base . DIRECTORY_SEPARATOR . 'NUL';
    $nulTxt = $base . DIRECTORY_SEPARATOR . 'NUL.txt';

    $legacy = @fopen('NUL', 'wb');
    $legacyOk = is_resource($legacy);
    record_result('bare NUL fopen works', $legacyOk, gettype($legacy));
    if ($legacyOk) {
        fclose($legacy);
    }

    expect_false('scoped NUL fopen is blocked', function () use ($nul) {
        return @fopen($nul, 'wb');
    });
    expect_false('scoped NUL file_exists is false', function () use ($nul) {
        clearstatcache(true, $nul);
        return @file_exists($nul);
    });
    expect_false('scoped NUL stat is blocked', function () use ($nul) {
        clearstatcache(true, $nul);
        return @stat($nul);
    });
    expect_false('scoped NUL mkdir is blocked', function () use ($nul) {
        return @mkdir($nul);
    });

    expect_false('scoped NUL.txt file_exists is false', function () use ($nulTxt) {
        clearstatcache(true, $nulTxt);
        return @file_exists($nulTxt);
    });
} finally {
    @unlink($nul);
    @unlink($nulTxt);
    @rmdir($nul);
    @rmdir($base);
}

if ($failures) {
    fwrite(STDERR, 'Failures: ' . implode(', ', $failures) . PHP_EOL);
    exit(1);
}

echo "All reserved device path checks passed.\n";
