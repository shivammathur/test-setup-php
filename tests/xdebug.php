<?php
if (phpversion('xdebug') !== getenv('EXPECTED_XDEBUG_VERSION')) {
    fwrite(STDERR, "Wrong Xdebug version\n"); exit(1);
}
xdebug_start_code_coverage();
require __DIR__ . '/coverage-fixture.php';
$coverage = xdebug_get_code_coverage();
xdebug_stop_code_coverage();
$fixture = realpath(__DIR__ . '/coverage-fixture.php');
if (!isset($coverage[$fixture]) || !in_array(1, $coverage[$fixture], true)) {
    fwrite(STDERR, "Xdebug code coverage failed\n"); exit(1);
}
echo 'PhpManager-installed Xdebug ', phpversion('xdebug'), " loaded and collected coverage\n";
