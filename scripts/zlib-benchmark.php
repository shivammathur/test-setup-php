<?php

declare(strict_types=1);

function option_value(array $options, string $name, string $default): string
{
    $value = $options[$name] ?? $default;
    return is_array($value) ? $default : (string) $value;
}

function make_payload(int $size): string
{
    $seed = "PHP zlib benchmark payload\n";
    $payload = '';
    $counter = 0;

    while (strlen($payload) < $size) {
        $hash = hash('sha256', $seed . $counter, true);
        $payload .= substr($seed, 0, 16) . $hash . pack('V', $counter) . str_repeat(chr(65 + ($counter % 26)), 12);
        $counter++;
    }

    return substr($payload, 0, $size);
}

function assert_same(string $feature, string $expected, string $actual): void
{
    if ($expected !== $actual) {
        fwrite(STDERR, $feature . " roundtrip failed\n");
        exit(1);
    }
}

function build_cases(string $payload): array
{
    $zlib = gzcompress($payload, 6);
    $raw = gzdeflate($payload, 6);
    $gzip = gzencode($payload, 6);

    if ($zlib === false || $raw === false || $gzip === false) {
        fwrite(STDERR, "Failed to prepare compressed payloads\n");
        exit(1);
    }

    $deflateContext = deflate_init(ZLIB_ENCODING_RAW, ['level' => 6]);
    $streamRaw = deflate_add($deflateContext, $payload, ZLIB_FINISH);
    if ($streamRaw === false) {
        fwrite(STDERR, "Failed to prepare streaming deflate payload\n");
        exit(1);
    }

    return [
        'crc32' => [
            'bytes' => strlen($payload),
            'callback' => static fn(): int => crc32($payload),
        ],
        'gzcompress' => [
            'bytes' => strlen($payload),
            'callback' => static fn(): string|false => gzcompress($payload, 6),
        ],
        'gzuncompress' => [
            'bytes' => strlen($payload),
            'callback' => static fn(): string|false => gzuncompress($zlib),
            'expect' => $payload,
        ],
        'gzdeflate' => [
            'bytes' => strlen($payload),
            'callback' => static fn(): string|false => gzdeflate($payload, 6),
        ],
        'gzinflate' => [
            'bytes' => strlen($payload),
            'callback' => static fn(): string|false => gzinflate($raw),
            'expect' => $payload,
        ],
        'gzencode' => [
            'bytes' => strlen($payload),
            'callback' => static fn(): string|false => gzencode($payload, 6),
        ],
        'gzdecode' => [
            'bytes' => strlen($payload),
            'callback' => static fn(): string|false => gzdecode($gzip),
            'expect' => $payload,
        ],
        'deflate_add' => [
            'bytes' => strlen($payload),
            'callback' => static function () use ($payload): string|false {
                $context = deflate_init(ZLIB_ENCODING_RAW, ['level' => 6]);
                return deflate_add($context, $payload, ZLIB_FINISH);
            },
        ],
        'inflate_add' => [
            'bytes' => strlen($payload),
            'callback' => static function () use ($streamRaw): string|false {
                $context = inflate_init(ZLIB_ENCODING_RAW);
                return inflate_add($context, $streamRaw, ZLIB_FINISH);
            },
            'expect' => $payload,
        ],
    ];
}

function smoke(): void
{
    if (!extension_loaded('zlib')) {
        fwrite(STDERR, "zlib extension is not loaded\n");
        exit(1);
    }

    $payload = make_payload(1024 * 1024);
    foreach (build_cases($payload) as $name => $case) {
        $result = $case['callback']();
        if ($result === false) {
            fwrite(STDERR, $name . " returned false\n");
            exit(1);
        }
        if (isset($case['expect'])) {
            assert_same($name, $case['expect'], (string) $result);
        }
    }

    $temporary = tempnam(sys_get_temp_dir(), 'zlib-smoke-');
    if ($temporary === false) {
        fwrite(STDERR, "Could not create temp file\n");
        exit(1);
    }

    $path = 'compress.zlib://' . $temporary;
    if (file_put_contents($path, $payload) === false) {
        fwrite(STDERR, "compress.zlib write failed\n");
        exit(1);
    }

    $read = file_get_contents($path);
    @unlink($temporary);
    assert_same('compress.zlib', $payload, (string) $read);

    echo "zlib smoke OK on PHP " . PHP_VERSION . PHP_EOL;
}

function median(array $values): float
{
    sort($values, SORT_NUMERIC);
    $count = count($values);
    $middle = intdiv($count, 2);

    if ($count % 2 === 1) {
        return (float) $values[$middle];
    }

    return ((float) $values[$middle - 1] + (float) $values[$middle]) / 2;
}

function benchmark(array $options): void
{
    if (!extension_loaded('zlib')) {
        fwrite(STDERR, "zlib extension is not loaded\n");
        exit(1);
    }

    $payloadMb = max(1, (int) option_value($options, 'payload-mb', '8'));
    $iterations = max(1, (int) option_value($options, 'iterations', '12'));
    $repeats = max(1, (int) option_value($options, 'repeats', '7'));
    $output = option_value($options, 'output', 'zlib-benchmark.json');
    $payload = make_payload($payloadMb * 1024 * 1024);
    $cases = build_cases($payload);
    $results = [];

    foreach ($cases as $name => $case) {
        $case['callback']();
        $seconds = [];

        for ($repeat = 0; $repeat < $repeats; $repeat++) {
            $start = hrtime(true);
            for ($iteration = 0; $iteration < $iterations; $iteration++) {
                $result = $case['callback']();
                if ($result === false) {
                    fwrite(STDERR, $name . " returned false\n");
                    exit(1);
                }
                if (isset($case['expect']) && $iteration === 0) {
                    assert_same($name, $case['expect'], (string) $result);
                }
            }
            $seconds[] = (hrtime(true) - $start) / 1_000_000_000;
        }

        $medianSeconds = median($seconds);
        $processedBytes = $case['bytes'] * $iterations;
        $results[] = [
            'name' => $name,
            'seconds' => $medianSeconds,
            'mib_per_second' => ($processedBytes / 1048576) / $medianSeconds,
            'payload_mib' => $payloadMb,
            'iterations' => $iterations,
            'repeats' => $repeats,
        ];
    }

    $document = [
        'php_version' => PHP_VERSION,
        'sapi' => PHP_SAPI,
        'zlib_loaded' => extension_loaded('zlib'),
        'payload_mib' => $payloadMb,
        'iterations' => $iterations,
        'repeats' => $repeats,
        'features' => $results,
    ];

    file_put_contents($output, json_encode($document, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
}

$options = getopt('', [
    'mode:',
    'payload-mb:',
    'iterations:',
    'repeats:',
    'output:',
]);

$mode = option_value($options, 'mode', 'smoke');
if ($mode === 'smoke') {
    smoke();
    exit(0);
}

if ($mode === 'benchmark') {
    benchmark($options);
    exit(0);
}

fwrite(STDERR, "Unknown mode: " . $mode . "\n");
exit(1);
