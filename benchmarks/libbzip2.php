<?php

declare(strict_types=1);

$options = getopt('', [
    'label:',
    'php-ref:',
    'arch:',
    'ts:',
    'output:',
]);

foreach (['label', 'php-ref', 'arch', 'ts', 'output'] as $required) {
    if (!isset($options[$required]) || $options[$required] === false || $options[$required] === '') {
        fwrite(STDERR, "Missing --$required\n");
        exit(2);
    }
}

if (!extension_loaded('bz2')) {
    fwrite(STDERR, "The bz2 extension is not loaded\n");
    exit(2);
}

function make_payload(int $size): string
{
    $chunk = '';
    for ($i = 0; strlen($chunk) < 8192; $i++) {
        $chunk .= hash('sha256', 'libbzip2 benchmark ' . $i) . "\n";
        $chunk .= str_repeat(chr(65 + ($i % 26)), 96) . "\n";
    }

    return substr(str_repeat($chunk, intdiv($size, strlen($chunk)) + 1), 0, $size);
}

function percentile(array $values, float $percentile): float
{
    sort($values, SORT_NUMERIC);
    $index = (int) floor((count($values) - 1) * $percentile);

    return $values[$index];
}

function run_benchmark(string $name, int $iterations, callable $callback): array
{
    for ($i = 0; $i < 3; $i++) {
        $callback();
    }

    gc_collect_cycles();
    $samples = [];
    for ($round = 0; $round < 7; $round++) {
        $start = hrtime(true);
        for ($i = 0; $i < $iterations; $i++) {
            $callback();
        }
        $elapsed = (hrtime(true) - $start) / 1_000_000;
        $samples[] = $elapsed / $iterations;
    }

    return [
        'name' => $name,
        'iterations' => $iterations,
        'median_ms' => percentile($samples, 0.50),
        'p90_ms' => percentile($samples, 0.90),
        'min_ms' => min($samples),
        'max_ms' => max($samples),
        'samples_ms' => $samples,
    ];
}

$payload256k = make_payload(256 * 1024);
$payload1m = make_payload(1024 * 1024);
$compressed256k = bzcompress($payload256k, 9, 30);
$compressed1m = bzcompress($payload1m, 9, 30);

if (!is_string($compressed256k) || !is_string($compressed1m)) {
    fwrite(STDERR, "Failed to prepare compressed payloads\n");
    exit(2);
}

$benchmarks = [];
$benchmarks[] = run_benchmark('bzcompress_256k', 48, static function () use ($payload256k): void {
    $compressed = bzcompress($payload256k, 9, 30);
    if (!is_string($compressed)) {
        throw new RuntimeException('bzcompress_256k failed');
    }
});

$benchmarks[] = run_benchmark('bzdecompress_256k', 120, static function () use ($compressed256k, $payload256k): void {
    $decompressed = bzdecompress($compressed256k);
    if ($decompressed !== $payload256k) {
        throw new RuntimeException('bzdecompress_256k failed');
    }
});

$benchmarks[] = run_benchmark('bzcompress_1m', 16, static function () use ($payload1m): void {
    $compressed = bzcompress($payload1m, 9, 30);
    if (!is_string($compressed)) {
        throw new RuntimeException('bzcompress_1m failed');
    }
});

$benchmarks[] = run_benchmark('bzdecompress_1m', 48, static function () use ($compressed1m, $payload1m): void {
    $decompressed = bzdecompress($compressed1m);
    if ($decompressed !== $payload1m) {
        throw new RuntimeException('bzdecompress_1m failed');
    }
});

$zipSupported = extension_loaded('zip')
    && class_exists('ZipArchive')
    && defined('ZipArchive::CM_BZIP2')
    && (!method_exists('ZipArchive', 'isCompressionMethodSupported')
        || ZipArchive::isCompressionMethodSupported(ZipArchive::CM_BZIP2, true));

if ($zipSupported) {
    $benchmarks[] = run_benchmark('zip_cm_bzip2_write_256k', 24, static function () use ($payload256k): void {
        $path = tempnam(sys_get_temp_dir(), 'zip-bz2-');
        if ($path === false) {
            throw new RuntimeException('tempnam failed');
        }

        $zip = new ZipArchive();
        if ($zip->open($path, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
            throw new RuntimeException('ZipArchive::open failed');
        }
        $zip->addFromString('payload.txt', $payload256k);
        $zip->setCompressionName('payload.txt', ZipArchive::CM_BZIP2, 9);
        $zip->close();
        unlink($path);
    });

    $zipPath = tempnam(sys_get_temp_dir(), 'zip-bz2-read-');
    if ($zipPath === false) {
        throw new RuntimeException('tempnam failed');
    }
    $zip = new ZipArchive();
    if ($zip->open($zipPath, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
        throw new RuntimeException('ZipArchive::open failed');
    }
    $zip->addFromString('payload.txt', $payload256k);
    $zip->setCompressionName('payload.txt', ZipArchive::CM_BZIP2, 9);
    $zip->close();

    $benchmarks[] = run_benchmark('zip_cm_bzip2_read_256k', 60, static function () use ($zipPath, $payload256k): void {
        $zip = new ZipArchive();
        if ($zip->open($zipPath) !== true) {
            throw new RuntimeException('ZipArchive::open read failed');
        }
        $contents = $zip->getFromName('payload.txt');
        $zip->close();
        if ($contents !== $payload256k) {
            throw new RuntimeException('ZipArchive bzip2 read failed');
        }
    });

    unlink($zipPath);
} else {
    $benchmarks[] = [
        'name' => 'zip_cm_bzip2_write_256k',
        'skipped' => true,
        'reason' => 'ZipArchive bzip2 compression is not available',
    ];
    $benchmarks[] = [
        'name' => 'zip_cm_bzip2_read_256k',
        'skipped' => true,
        'reason' => 'ZipArchive bzip2 compression is not available',
    ];
}

$result = [
    'label' => $options['label'],
    'php_ref' => $options['php-ref'],
    'arch' => $options['arch'],
    'ts' => $options['ts'],
    'php_version' => PHP_VERSION,
    'php_binary' => PHP_BINARY,
    'platform' => PHP_OS_FAMILY,
    'extensions' => [
        'bz2' => phpversion('bz2'),
        'zip' => extension_loaded('zip') ? phpversion('zip') : null,
    ],
    'payloads' => [
        'payload256k_sha256' => hash('sha256', $payload256k),
        'payload1m_sha256' => hash('sha256', $payload1m),
        'compressed256k_bytes' => strlen($compressed256k),
        'compressed1m_bytes' => strlen($compressed1m),
    ],
    'benchmarks' => $benchmarks,
];

file_put_contents(
    $options['output'],
    json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n"
);

