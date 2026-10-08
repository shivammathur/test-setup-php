<?php
declare(strict_types=1);

function check(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

check(PHP_MAJOR_VERSION === 8 && PHP_MINOR_VERSION === 5, 'Expected PHP 8.5');
check((bool) PHP_ZTS === (getenv('EXPECTED_TS') === 'zts'), 'Wrong thread-safety mode');
check(extension_loaded('swoole'), 'Swoole failed to load');
$binary = ini_get('extension_dir') . DIRECTORY_SEPARATOR
    . (PHP_OS_FAMILY === 'Windows' ? 'php_swoole.dll' : 'swoole.so');
check(is_file($binary), 'Swoole binary missing');
echo json_encode([
    'php' => PHP_VERSION,
    'zts' => (bool) PHP_ZTS,
    'os' => PHP_OS_FAMILY,
    'arch' => php_uname('m'),
    'swoole' => phpversion('swoole'),
    'binary' => $binary,
    'sha256' => hash_file('sha256', $binary),
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;

$received = [];
Swoole\Coroutine\run(function () use (&$received): void {
    $channel = new Swoole\Coroutine\Channel(4);
    for ($i = 0; $i < 4; $i++) {
        Swoole\Coroutine::create(function () use ($channel, $i): void {
            Swoole\Coroutine::sleep(0.01);
            check($channel->push($i, 5), 'Coroutine channel push failed');
        });
    }
    for ($i = 0; $i < 4; $i++) {
        $value = $channel->pop(5);
        check($value !== false, 'Coroutine channel timed out');
        $received[] = $value;
    }
    $channel->close();
});
sort($received);
check($received === [0, 1, 2, 3], 'Unexpected coroutine results');
echo "PASS: Swoole loaded; coroutine scheduling, timers, and channels work.", PHP_EOL;
