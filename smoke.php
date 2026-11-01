<?php

$expected = $argv[1];
if (PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION !== getenv('EXPECTED_PHP')) {
    throw new RuntimeException('Unexpected PHP version: ' . PHP_VERSION);
}
if (!extension_loaded('ev') || phpversion('ev') !== $expected) {
    throw new RuntimeException('Expected ev ' . $expected . ', got ' . phpversion('ev'));
}
$called = false;
$timer = new EvTimer(0.01, 0, function ($watcher) use (&$called) {
    $called = true;
    $watcher->stop();
});
Ev::run();
if (!$called) {
    throw new RuntimeException('Ev event-loop timer did not fire');
}
printf("PHP %s; ev %s; event-loop timer passed.\n", PHP_VERSION, phpversion('ev'));
