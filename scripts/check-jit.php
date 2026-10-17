<?php
// Run outside the timed samples: verify the real benchmark emits native code,
// rather than merely checking that JIT was configured at process startup.
$before = opcache_get_status(false)['jit'] ?? null;
if (!$before || !$before['on'] || $before['kind'] !== 5) {
    fwrite(STDERR, "Tracing JIT is not active\n");
    exit(1);
}
ob_start();
$script = $argv[1];
$argv = [$script];
$argc = 1;
require $script;
$checksum = trim(ob_get_clean());
$after = opcache_get_status(false)['jit'];
$generated = $before['buffer_free'] - $after['buffer_free'];
if ($generated <= 0) {
    fwrite(STDERR, "Benchmark did not emit JIT code\n");
    exit(1);
}
echo json_encode([
    'before' => $before,
    'after' => $after,
    'generated_bytes' => $generated,
    'checksum' => $checksum,
], JSON_THROW_ON_ERROR), "\n";
