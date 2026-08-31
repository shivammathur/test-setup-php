<?php

$value = isset($_GET['value']) && (int) $_GET['value'] === 1;
$request = isset($_GET['request']) ? (int) $_GET['request'] : 0;

/*
 * Allocate before linking gh21710.inc on the second request shape. This
 * mirrors the upstream fork-based reproducer and increases the chance that a
 * stale heap op_array from the preceding request points at reused memory.
 */
$buf = [];
if ($value) {
    for ($i = 0; $i < 100; $i++) {
        $buf[] = str_repeat('a', $i * 100);
    }
}

require __DIR__ . '/gh21710.inc';

$call = getenv('call_user_func');
for ($i = 0; $i < 1000; $i++) {
    $call('C::f', [$value]);
}

$status = opcache_get_status(false);
$jit = is_array($status) ? ($status['jit'] ?? []) : [];
header('Content-Type: text/plain');
echo 'request=' . $request . "\n";
echo 'value=' . (int) $value . "\n";
echo 'pid=' . getmypid() . "\n";
echo 'php=' . PHP_VERSION . "\n";
echo 'jit_enabled=' . (int) ($jit['enabled'] ?? false) . "\n";
echo 'jit_on=' . (int) ($jit['on'] ?? false) . "\n";
echo 'result=' . (int) $call('C::f', [$value]) . "\n";
