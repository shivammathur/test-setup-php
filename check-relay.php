<?php

$loaded = extension_loaded('relay');
$version = phpversion('relay');
$input = getenv('RELAY_INPUT');
$threadSafe = (bool) PHP_ZTS;
echo 'RELAY_RESULT ', json_encode([
    'php' => PHP_VERSION,
    'os' => PHP_OS_FAMILY,
    'arch' => php_uname('m'),
    'zts' => $threadSafe,
    'input' => $input,
    'loaded' => $loaded,
    'version' => $version,
    'classes' => $loaded ? count((new ReflectionExtension('relay'))->getClasses()) : 0,
]), PHP_EOL;

if (PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION !== getenv('EXPECTED_PHP')
    || $threadSafe !== (getenv('phpts') === 'zts')
    || !$loaded) {
    exit(1);
}
if (preg_match('/^relay-v?([0-9.]+)$/', $input, $matches) && $version !== $matches[1]) {
    exit(2);
}
if ($input === 'relay-nightly' && stripos($version, 'dev') === false) {
    exit(3);
}
