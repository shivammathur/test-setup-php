<?php

declare(strict_types=1);

const DATA_SIZES = [
    1024,
    64 * 1024,
    1024 * 1024,
    10 * 1024 * 1024,
];

const COMPRESSION_LEVELS = [1, 6, 9];
const CHUNK_SIZE = 16384;

function option_value(array $options, string $name, string $default): string
{
    $value = $options[$name] ?? $default;
    return is_array($value) ? $default : (string) $value;
}

function fail(string $message): never
{
    fwrite(STDERR, $message . PHP_EOL);
    exit(1);
}

function require_zlib(): void
{
    if (!extension_loaded('zlib')) {
        fail('zlib extension is not loaded');
    }
}

function format_size(int $size): string
{
    if ($size < 1024) {
        return $size . ' B';
    }

    if ($size < 1024 * 1024) {
        return intdiv($size, 1024) . ' KB';
    }

    return intdiv($size, 1024 * 1024) . ' MB';
}

function generate_text_data(int $size): string
{
    $base = (
        'The quick brown fox jumps over the lazy dog. ' .
        'Lorem ipsum dolor sit amet, consectetur adipiscing elit. ' .
        'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ' .
        'Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris. '
    );
    $repeats = intdiv($size, strlen($base)) + 1;

    return substr(str_repeat($base, $repeats), 0, $size);
}

function generate_binary_data(int $size): string
{
    $chunks = [];
    $counter = 0;
    $length = 0;

    while ($length < $size) {
        $chunk = hash('sha256', 'zlib-py-style-binary-' . $counter, true);
        $chunks[] = $chunk;
        $length += strlen($chunk);
        $counter++;
    }

    return substr(implode('', $chunks), 0, $size);
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

function benchmark_call(callable $callback, int $iterations, int $warmup = 2): float
{
    for ($i = 0; $i < $warmup; $i++) {
        $callback();
    }

    $times = [];
    for ($i = 0; $i < $iterations; $i++) {
        $start = hrtime(true);
        $callback();
        $times[] = (hrtime(true) - $start) / 1_000_000_000;
    }

    return median($times);
}

function one_shot_compress(string $data, int $level): string
{
    $compressed = gzcompress($data, $level);
    if ($compressed === false) {
        fail('gzcompress returned false');
    }

    return $compressed;
}

function one_shot_decompress(string $compressed): string
{
    $decompressed = gzuncompress($compressed);
    if ($decompressed === false) {
        fail('gzuncompress returned false');
    }

    return $decompressed;
}

function stream_compress(string $data, int $level): string
{
    $context = deflate_init(ZLIB_ENCODING_DEFLATE, ['level' => $level]);
    if ($context === false) {
        fail('deflate_init returned false');
    }

    $output = '';
    $length = strlen($data);
    for ($offset = 0; $offset < $length; $offset += CHUNK_SIZE) {
        $flush = ($offset + CHUNK_SIZE >= $length) ? ZLIB_FINISH : ZLIB_NO_FLUSH;
        $part = deflate_add($context, substr($data, $offset, CHUNK_SIZE), $flush);
        if ($part === false) {
            fail('deflate_add returned false');
        }
        $output .= $part;
    }

    return $output;
}

function stream_decompress(string $compressed): string
{
    $context = inflate_init(ZLIB_ENCODING_DEFLATE);
    if ($context === false) {
        fail('inflate_init returned false');
    }

    $output = '';
    $length = strlen($compressed);
    for ($offset = 0; $offset < $length; $offset += CHUNK_SIZE) {
        $flush = ($offset + CHUNK_SIZE >= $length) ? ZLIB_FINISH : ZLIB_NO_FLUSH;
        $part = inflate_add($context, substr($compressed, $offset, CHUNK_SIZE), $flush);
        if ($part === false) {
            fail('inflate_add returned false');
        }
        $output .= $part;
    }

    return $output;
}

function fixture_key(int $size, int $level): string
{
    return $size . ':' . $level;
}

function write_fixtures(string $output): void
{
    require_zlib();

    $fixtures = [
        'source' => 'zlib 1.3.2 PHP build',
        'encoding' => 'base64',
        'compressed_text' => [],
    ];

    foreach (DATA_SIZES as $size) {
        $data = generate_text_data($size);
        foreach (COMPRESSION_LEVELS as $level) {
            $fixtures['compressed_text'][fixture_key($size, $level)] = [
                'size' => $size,
                'level' => $level,
                'compressed' => base64_encode(one_shot_compress($data, $level)),
            ];
        }
    }

    file_put_contents($output, json_encode($fixtures, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
}

function load_fixtures(string $fixtureFile): array
{
    if ($fixtureFile === '') {
        return [];
    }

    if (!is_file($fixtureFile)) {
        fail('Fixture file does not exist: ' . $fixtureFile);
    }

    $fixtures = json_decode((string) file_get_contents($fixtureFile), true, 512, JSON_THROW_ON_ERROR);
    if (!is_array($fixtures)) {
        fail('Fixture file did not decode to an array');
    }

    return $fixtures;
}

function compressed_fixture(array $fixtures, int $size, int $level, string $fallbackData): string
{
    $key = fixture_key($size, $level);
    if (isset($fixtures['compressed_text'][$key]['compressed'])) {
        $decoded = base64_decode((string) $fixtures['compressed_text'][$key]['compressed'], true);
        if ($decoded === false) {
            fail('Fixture base64 decode failed for ' . $key);
        }

        return $decoded;
    }

    return one_shot_compress($fallbackData, $level);
}

function add_result(
    array &$results,
    string $group,
    string $name,
    int $inputBytes,
    int $iterations,
    callable $callback,
    ?int $size = null,
    ?int $level = null,
    ?int $outputBytes = null
): void {
    $seconds = benchmark_call($callback, $iterations);
    $row = [
        'name' => $name,
        'group' => $group,
        'seconds' => $seconds,
        'mib_per_second' => ($inputBytes / 1048576) / $seconds,
        'input_bytes' => $inputBytes,
        'iterations' => $iterations,
        'warmup' => 2,
    ];

    if ($size !== null) {
        $row['size'] = $size;
        $row['size_label'] = format_size($size);
    }

    if ($level !== null) {
        $row['level'] = $level;
    }

    if ($outputBytes !== null) {
        $row['output_bytes'] = $outputBytes;
        $row['compression_ratio'] = $outputBytes / $inputBytes;
    }

    $results[] = $row;
}

function run_benchmark(string $fixtureFile, string $output): void
{
    require_zlib();

    $fixtures = load_fixtures($fixtureFile);
    $features = [];
    $ratios = [];
    $skipped = [
        [
            'name' => 'adler32',
            'reason' => 'PHP userland does not expose zlib adler32',
        ],
    ];

    foreach (DATA_SIZES as $size) {
        $data = generate_text_data($size);
        foreach (COMPRESSION_LEVELS as $level) {
            $iterations = max(3, intdiv(500, intdiv($size, 1024) + 1));
            $compressed = one_shot_compress($data, $level);
            $name = 'compress text ' . format_size($size) . ' level=' . $level;

            add_result(
                $features,
                'oneshot_compress',
                $name,
                $size,
                $iterations,
                static fn(): string => one_shot_compress($data, $level),
                $size,
                $level,
                strlen($compressed)
            );
        }
    }

    foreach (DATA_SIZES as $size) {
        $data = generate_text_data($size);
        foreach (COMPRESSION_LEVELS as $level) {
            $compressed = compressed_fixture($fixtures, $size, $level, $data);
            $decompressed = one_shot_decompress($compressed);
            if ($decompressed !== $data) {
                fail('gzuncompress roundtrip failed for ' . format_size($size) . ' level=' . $level);
            }

            $iterations = max(3, intdiv(500, intdiv($size, 1024) + 1));
            $name = 'decompress text ' . format_size($size) . ' level=' . $level;

            add_result(
                $features,
                'oneshot_decompress',
                $name,
                $size,
                $iterations,
                static fn(): string => one_shot_decompress($compressed),
                $size,
                $level,
                strlen($compressed)
            );
        }
    }

    foreach (DATA_SIZES as $size) {
        $data = generate_text_data($size);
        $level = 6;
        $compressed = stream_compress($data, $level);
        $inflated = one_shot_decompress($compressed);
        if ($inflated !== $data) {
            fail('stream deflate output did not roundtrip for ' . format_size($size));
        }

        $iterations = max(3, intdiv(200, intdiv($size, 1024) + 1));
        $name = 'stream compress text ' . format_size($size) . ' L6';

        add_result(
            $features,
            'stream_compress',
            $name,
            $size,
            $iterations,
            static fn(): string => stream_compress($data, $level),
            $size,
            $level,
            strlen($compressed)
        );
    }

    foreach (DATA_SIZES as $size) {
        $data = generate_text_data($size);
        $level = 6;
        $compressed = compressed_fixture($fixtures, $size, $level, $data);
        $decompressed = stream_decompress($compressed);
        if ($decompressed !== $data) {
            fail('stream inflate roundtrip failed for ' . format_size($size));
        }

        $iterations = max(3, intdiv(200, intdiv($size, 1024) + 1));
        $name = 'stream decompress text ' . format_size($size) . ' L6';

        add_result(
            $features,
            'stream_decompress',
            $name,
            $size,
            $iterations,
            static fn(): string => stream_decompress($compressed),
            $size,
            $level,
            strlen($compressed)
        );
    }

    foreach (DATA_SIZES as $size) {
        $data = generate_text_data($size);
        $iterations = max(5, intdiv(1000, intdiv($size, 1024) + 1));
        $name = 'crc32 text ' . format_size($size);

        add_result(
            $features,
            'checksum',
            $name,
            $size,
            $iterations,
            static fn(): int => crc32($data),
            $size
        );
    }

    foreach ([64 * 1024, 1024 * 1024] as $size) {
        $data = generate_binary_data($size);
        $level = 6;
        $compressed = one_shot_compress($data, $level);
        $iterations = max(3, intdiv(200, intdiv($size, 1024) + 1));
        $name = 'compress binary ' . format_size($size) . ' L6';

        add_result(
            $features,
            'binary_compress',
            $name,
            $size,
            $iterations,
            static fn(): string => one_shot_compress($data, $level),
            $size,
            $level,
            strlen($compressed)
        );
    }

    foreach ([1024, 64 * 1024, 1024 * 1024] as $size) {
        $data = generate_text_data($size);
        foreach (COMPRESSION_LEVELS as $level) {
            $compressed = one_shot_compress($data, $level);
            $ratios[] = [
                'name' => 'text ' . format_size($size) . ' L' . $level,
                'size' => $size,
                'size_label' => format_size($size),
                'level' => $level,
                'input_bytes' => $size,
                'output_bytes' => strlen($compressed),
                'compression_ratio' => strlen($compressed) / $size,
            ];
        }
    }

    $document = [
        'benchmark' => 'zlib-py-style',
        'php_version' => PHP_VERSION,
        'sapi' => PHP_SAPI,
        'zlib_loaded' => extension_loaded('zlib'),
        'features' => $features,
        'ratios' => $ratios,
        'skipped' => $skipped,
    ];

    file_put_contents($output, json_encode($document, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
}

$options = getopt('', [
    'mode:',
    'output:',
    'fixture:',
]);

$mode = option_value($options, 'mode', 'benchmark');
$output = option_value($options, 'output', 'zlib-py-style-benchmark.json');

if ($mode === 'fixtures') {
    write_fixtures($output);
    exit(0);
}

if ($mode === 'benchmark') {
    run_benchmark(option_value($options, 'fixture', ''), $output);
    exit(0);
}

fail('Unknown mode: ' . $mode);
