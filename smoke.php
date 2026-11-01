<?php

$extension = getenv('EXTENSION');
$expected = getenv('EXPECTED_VERSION');
if (PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION !== getenv('EXPECTED_PHP')) {
    throw new RuntimeException('Unexpected PHP version: ' . PHP_VERSION);
}
if (!extension_loaded($extension) || phpversion($extension) !== $expected) {
    throw new RuntimeException("Expected $extension $expected, got " . phpversion($extension));
}
if ($extension === 'swoole') {
    $completed = false;
    Swoole\Coroutine\run(function () use (&$completed) {
        $channel = new Swoole\Coroutine\Channel(1);
        Swoole\Coroutine::create(function () use ($channel) {
            if (!$channel->push('prerelease-ok', 1.0)) {
                throw new RuntimeException('Coroutine channel push failed');
            }
        });
        if ($channel->pop(1.0) !== 'prerelease-ok') {
            throw new RuntimeException('Coroutine channel round trip failed');
        }
        $channel->close();
        $completed = true;
    });
    if (!$completed) {
        throw new RuntimeException('Coroutine scheduler did not complete');
    }
    echo "Coroutine channel round trip passed.\n";
} elseif ($extension === 'vld') {
    if (ini_get('vld.active') === false || ini_get('vld.execute') === false) {
        throw new RuntimeException('VLD ini directives missing');
    }
} else {
    throw new RuntimeException("Unexpected extension: $extension");
}
printf("PHP %s; %s %s loaded and runtime checks passed.\n", PHP_VERSION, $extension, phpversion($extension));
