<?php

declare(strict_types=1);

function fail(string $message): void
{
    fwrite(STDERR, "FAIL: {$message}\n");
    exit(1);
}

function pass(string $message): void
{
    fwrite(STDOUT, "PASS: {$message}\n");
}

function assert_true(bool $condition, string $message): void
{
    if (!$condition) {
        fail($message);
    }
}

function assert_same($expected, $actual, string $message): void
{
    if ($expected !== $actual) {
        fail(
            $message
            . "\nExpected: " . var_export($expected, true)
            . "\nActual: " . var_export($actual, true)
        );
    }
}

function assert_contains(string $needle, string $haystack, string $message): void
{
    if (strpos($haystack, $needle) === false) {
        fail($message . "\nNeedle: {$needle}\nHaystack: {$haystack}");
    }
}

function request(string $url, ?string $acceptEncoding = null, bool $decode = true): array
{
    $headers = [];
    $ch = curl_init($url);
    if ($ch === false) {
        fail("Failed to initialize curl");
    }

    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_TIMEOUT => 20,
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_HTTP_CONTENT_DECODING => $decode,
        CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_1_1,
        CURLOPT_HEADERFUNCTION => static function ($ch, string $line) use (&$headers): int {
            $trimmed = trim($line);
            if ($trimmed !== '' && strpos($trimmed, ':') !== false) {
                [$name, $value] = explode(':', $trimmed, 2);
                $headers[strtolower(trim($name))] = trim($value);
            }
            return strlen($line);
        },
    ]);

    if ($acceptEncoding !== null) {
        curl_setopt($ch, CURLOPT_ACCEPT_ENCODING, $acceptEncoding);
    }

    $body = curl_exec($ch);
    if ($body === false) {
        $error = curl_error($ch);
        curl_close($ch);
        fail("curl_exec failed for {$url}: {$error}");
    }

    $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);

    return [
        'status' => $status,
        'headers' => $headers,
        'body' => $body,
    ];
}

function header_value(array $response, string $name): string
{
    return $response['headers'][strtolower($name)] ?? '';
}

$baseUrl = isset($argv[1]) ? rtrim($argv[1], '/') : '';
$label = $argv[2] ?? basename((string) PHP_BINARY);

if ($baseUrl === '') {
    fail('Base URL is required');
}

fwrite(STDOUT, "Testing {$label} with " . PHP_VERSION . ' (' . (PHP_ZTS ? 'TS' : 'NTS') . ')' . PHP_EOL);

assert_true(extension_loaded('curl'), 'curl extension is not loaded');
assert_true(function_exists('curl_version'), 'curl_version() is unavailable');

$version = curl_version();
assert_true(defined('CURL_VERSION_BROTLI'), 'CURL_VERSION_BROTLI is not defined');
assert_true(defined('CURL_VERSION_ZSTD'), 'CURL_VERSION_ZSTD is not defined');
assert_true(($version['features'] & CURL_VERSION_BROTLI) !== 0, 'libcurl missing Brotli feature flag');
assert_true(($version['features'] & CURL_VERSION_ZSTD) !== 0, 'libcurl missing Zstd feature flag');
pass('curl feature flags report Brotli and Zstd support');

$echo = request("{$baseUrl}/echo");
assert_same(200, $echo['status'], '/echo should respond successfully');
assert_contains('"accept_encoding"', $echo['body'], '/echo should return JSON request metadata');
pass('echo endpoint is reachable');

$brotliRejected = request("{$baseUrl}/brotli");
assert_same(406, $brotliRejected['status'], 'Brotli endpoint should reject requests without Accept-Encoding');
assert_contains('"required": "br"', $brotliRejected['body'], 'Brotli rejection should describe the missing encoding');
pass('brotli endpoint rejects requests without Brotli negotiation');

$brotliAccepted = request("{$baseUrl}/brotli", '');
assert_same(200, $brotliAccepted['status'], 'Brotli request should succeed with automatic encoding negotiation');
assert_same("brotli payload ok\n", $brotliAccepted['body'], 'Brotli response body should be decoded by curl');
assert_same('br', strtolower(header_value($brotliAccepted, 'x-selected-encoding')), 'Server should choose Brotli');
assert_contains('br', strtolower(header_value($brotliAccepted, 'x-accept-encoding-received')), 'Server should observe br in Accept-Encoding');
pass('curl negotiates and decodes Brotli content');

$zstdAccepted = request("{$baseUrl}/zstd", '');
assert_same(200, $zstdAccepted['status'], 'Zstd request should succeed with automatic encoding negotiation');
assert_same("zstd payload ok\n", $zstdAccepted['body'], 'Zstd response body should be decoded by curl');
assert_same('zstd', strtolower(header_value($zstdAccepted, 'x-selected-encoding')), 'Server should choose Zstd');
assert_contains('zstd', strtolower(header_value($zstdAccepted, 'x-accept-encoding-received')), 'Server should observe zstd in Accept-Encoding');
pass('curl negotiates and decodes Zstd content');

$negotiated = request("{$baseUrl}/negotiate", '');
assert_same(200, $negotiated['status'], 'Negotiated request should succeed');
assert_same("negotiate payload ok\n", $negotiated['body'], 'Negotiated response should be decoded by curl');
assert_same('br', strtolower(header_value($negotiated, 'x-selected-encoding')), 'Server should prefer Brotli when both encodings are advertised');
pass('server parses Accept-Encoding and selects Brotli when available');

$brotliRaw = request("{$baseUrl}/brotli", 'br', false);
assert_same(200, $brotliRaw['status'], 'Raw Brotli request should succeed');
assert_same('br', strtolower(header_value($brotliRaw, 'content-encoding')), 'Raw Brotli response should retain its Content-Encoding header');
assert_true($brotliRaw['body'] !== "brotli payload ok\n", 'Raw Brotli response should not already be decoded');
pass('raw Brotli response remains compressed when content decoding is disabled');

$zstdRaw = request("{$baseUrl}/zstd", 'zstd', false);
assert_same(200, $zstdRaw['status'], 'Raw Zstd request should succeed');
assert_same('zstd', strtolower(header_value($zstdRaw, 'content-encoding')), 'Raw Zstd response should retain its Content-Encoding header');
assert_true($zstdRaw['body'] !== "zstd payload ok\n", 'Raw Zstd response should not already be decoded');
pass('raw Zstd response remains compressed when content decoding is disabled');

fwrite(STDOUT, "All curl encoding tests passed for {$label}\n");
