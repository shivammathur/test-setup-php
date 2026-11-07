<?php
$dir = $argv[1];
$marker = $argv[2] ?? '';
$status = opcache_get_status(false);
if (!$status || !$status['opcache_enabled']) {
    throw new RuntimeException('OPcache is not enabled');
}
if ($marker !== '' && !opcache_is_script_cached($marker)) {
    throw new RuntimeException('The worker did not reattach to the holder cache');
}
echo 'START ', json_encode([
    'version' => PHP_VERSION, 'zts' => PHP_ZTS, 'bits' => PHP_INT_SIZE * 8,
    'jit' => $status['jit'] ?? null, 'reattached' => $marker !== '',
]), "\n";
mkdir($dir);
for ($i = 0; $i < 20000; $i++) {
    $file = "$dir/c$i.php";
    file_put_contents($file, "<?php class C$i extends ArrayObject { public function m(int \$a): int { return \$a + $i; } }\n");
    require $file;
    unlink($file);
    $status = opcache_get_status(false);
    $free = $status['memory_usage']['free_memory'];
    if ($i % 1000 === 0 || $free < 65536 || $status['cache_full']) {
        echo 'PROGRESS ', json_encode(['files' => $i + 1, 'free' => $free]), "\n";
    }
    if ($status['cache_full']) {
        $stats = $status['opcache_statistics'];
        if ($free >= 65536 || $stats['num_cached_keys'] >= $stats['max_cached_keys']) {
            throw new RuntimeException('Cache filled for a reason other than shared-memory exhaustion');
        }
        rmdir($dir);
        echo 'FULL ', json_encode(['files' => $i + 1, 'free' => $free, 'cached' => $stats['num_cached_scripts']]), "\n";
        exit(0);
    }
}
throw new RuntimeException('Cache did not fill within the bounded workload');
