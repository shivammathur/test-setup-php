<?php
declare(strict_types=1);
function check(bool $condition, string $message): void {
    if (!$condition) {
        throw new RuntimeException($message . ': ' . (rrd_error() ?: 'no RRD error'));
    }
}
check(extension_loaded('rrd'), 'RRD extension loads');
$start = intdiv(time(), 60) * 60 - 1200;
$file = 'runtime-' . getmypid() . '.rrd';
$png = 'runtime-' . getmypid() . '.png';
check(rrd_create($file, ['--start', (string) $start, '--step', '60', 'DS:value:GAUGE:120:U:U', 'RRA:AVERAGE:0.5:1:100']), 'Create database');
try {
    $updates = [];
    for ($i = 1; $i <= 10; $i++) {
        $updates[] = ($start + $i * 60) . ':' . ($i * 3);
    }
    check(rrd_update($file, $updates), 'Update database');
    $fetch = rrd_fetch($file, ['AVERAGE', '--start', (string) $start, '--end', (string) ($start + 660)]);
    check(is_array($fetch) && isset($fetch['data']['value']), 'Fetch series');
    check(count(array_filter($fetch['data']['value'], static fn($value): bool => is_finite($value) && $value > 0)) > 0, 'Fetched values');
    $graph = rrd_graph($png, ['--start', (string) $start, '--end', (string) ($start + 660), '--width', '240', '--height', '100', '--title', 'GLib 2.90.0 PHP RRD QA', "DEF:v={$file}:value:AVERAGE", 'LINE1:v#FF0000:value']);
    check(is_array($graph), 'Render graph');
    $data = file_get_contents($png);
    check(is_string($data) && str_starts_with($data, "\x89PNG\r\n\x1a\n") && strlen($data) > 1000, 'PNG graph bytes');
    echo json_encode(['php' => PHP_VERSION, 'architecture' => PHP_INT_SIZE * 8, 'zts' => PHP_ZTS, 'rrd' => phpversion('rrd'), 'checks' => 7], JSON_THROW_ON_ERROR), "\n";
} finally {
    @unlink($file);
    @unlink($png);
}
