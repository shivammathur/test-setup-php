<?php

declare(strict_types=1);

$options = getopt('', [
    'mode:',
    'php-target:',
    'php-run-id:',
    'arch:',
    'ts:',
    'vs:',
    'extensions:',
    'json:',
    'junit:',
]);

$results = [];
$requestedExtensions = array_values(array_filter(
    array_map('trim', explode(',', (string)($options['extensions'] ?? ''))),
    static fn (string $extension): bool => $extension !== ''
));

function record_result(string $name, string $status, string $message = ''): void
{
    global $results;
    $results[] = [
        'name' => $name,
        'status' => $status,
        'message' => $message,
    ];
    echo strtoupper($status) . " $name";
    if ($message !== '') {
        echo " - $message";
    }
    echo PHP_EOL;
}

function pass(string $name, string $message = ''): void
{
    record_result($name, 'pass', $message);
}

function skip_case(string $name, string $message): void
{
    record_result($name, 'skip', $message);
}

function fail_case(string $name, string $message): void
{
    record_result($name, 'fail', $message);
}

function check(string $name, callable $callback): void
{
    try {
        $callback();
        pass($name);
    } catch (Throwable $throwable) {
        fail_case($name, $throwable->getMessage());
    }
}

function require_true(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

function describe_value(mixed $value): string
{
    if (is_string($value)) {
        $length = strlen($value);
        $preview = substr($value, 0, 160);
        $suffix = $length > 160 ? "...($length bytes)" : '';
        return var_export($preview . $suffix, true);
    }

    return var_export($value, true);
}

function require_same(mixed $expected, mixed $actual, string $message): void
{
    if ($expected !== $actual) {
        throw new RuntimeException($message . ' expected=' . describe_value($expected) . ' actual=' . describe_value($actual));
    }
}

function extension_requested(string $name): bool
{
    global $requestedExtensions;
    return in_array($name, $requestedExtensions, true);
}

function maybe(string $extension, string $name, callable $callback): void
{
    if (!extension_requested($extension)) {
        skip_case($name, "$extension was not requested for this run");
        return;
    }
    if (!extension_loaded($extension)) {
        fail_case($name, "$extension is not loaded");
        return;
    }
    check($name, $callback);
}

check('zlib raw/zlib/gzip round trips', function (): void {
    require_true(extension_loaded('zlib'), 'zlib extension is not loaded');
    $payload = str_repeat('zlib-rs extension compatibility payload ', 2048);
    $defaultCompression = defined('Z_DEFAULT_COMPRESSION') ? constant('Z_DEFAULT_COMPRESSION') : -1;

    $raw = gzdeflate($payload, $defaultCompression);
    require_true(is_string($raw) && $raw !== '', 'gzdeflate returned no data');
    require_same($payload, gzinflate($raw), 'gzinflate raw round trip failed');

    $wrapped = gzcompress($payload, $defaultCompression);
    require_true(is_string($wrapped) && $wrapped !== '', 'gzcompress returned no data');
    require_same($payload, gzuncompress($wrapped), 'gzuncompress round trip failed');

    $gzip = gzencode($payload, $defaultCompression);
    require_true(is_string($gzip) && str_starts_with($gzip, "\x1f\x8b"), 'gzencode did not produce a gzip stream');
    require_same($payload, gzdecode($gzip), 'gzdecode round trip failed');
});

check('zlib stream filter flush round trip', function (): void {
    $payload = str_repeat('0123456789abcdef', 4096);
    $temp = fopen('php://temp', 'w+');
    require_true(is_resource($temp), 'failed to open temp stream');
    $filter = stream_filter_append($temp, 'zlib.deflate', STREAM_FILTER_WRITE);
    require_true(is_resource($filter), 'failed to append zlib.deflate filter');
    fwrite($temp, $payload);
    fflush($temp);
    require_true(stream_filter_remove($filter), 'failed to remove zlib.deflate filter');
    rewind($temp);
    $compressed = stream_get_contents($temp);
    fclose($temp);
    require_true(is_string($compressed) && $compressed !== '', 'stream filter produced no data');
    $decoded = @zlib_decode($compressed);
    if ($decoded === false) {
        $decoded = @gzinflate($compressed);
    }
    if ($decoded === false) {
        $decoded = @gzuncompress($compressed);
    }
    require_same($payload, $decoded, 'zlib stream filter round trip failed');
});

check('extension request set', function () use ($requestedExtensions): void {
    require_true($requestedExtensions !== [], 'no extension list was passed to the compatibility suite');
});

maybe('memcache', 'memcache compression configuration surface', function (): void {
    require_true(class_exists('Memcache'), 'Memcache class missing');
    $host = getenv('ZLIB_COMPAT_MEMCACHED_HOST') ?: '127.0.0.1';
    $port = (int)(getenv('ZLIB_COMPAT_MEMCACHED_PORT') ?: 11211);
    $memcache = new Memcache();
    require_true(@$memcache->connect($host, $port), "failed to connect to memcached at $host:$port");
    require_true(method_exists($memcache, 'setCompressThreshold'), 'setCompressThreshold missing');
    require_true($memcache->setCompressThreshold(128, 0.2), 'setCompressThreshold failed');
    require_true(defined('MEMCACHE_COMPRESSED'), 'MEMCACHE_COMPRESSED constant missing');
    $key = 'zlib-rs-memcache-' . bin2hex(random_bytes(4));
    $payload = str_repeat('memcache zlib-rs compression payload ', 2048);
    require_true($memcache->set($key, $payload, MEMCACHE_COMPRESSED, 60), 'compressed memcache set failed');
    require_same($payload, $memcache->get($key), 'compressed memcache get round trip failed');
    $memcache->delete($key);
    $memcache->close();
});

maybe('memcached', 'memcached compression options', function (): void {
    require_true(class_exists('Memcached'), 'Memcached class missing');
    $host = getenv('ZLIB_COMPAT_MEMCACHED_HOST') ?: '127.0.0.1';
    $port = (int)(getenv('ZLIB_COMPAT_MEMCACHED_PORT') ?: 11211);
    $memcached = new Memcached('zlib-rs-' . bin2hex(random_bytes(4)));
    require_true(defined('Memcached::OPT_COMPRESSION'), 'OPT_COMPRESSION constant missing');
    require_true($memcached->addServer($host, $port), "failed to add memcached server $host:$port");
    require_true($memcached->setOption(Memcached::OPT_COMPRESSION, true), 'enabling compression failed');
    if (defined('Memcached::OPT_COMPRESSION_TYPE') && defined('Memcached::COMPRESSION_ZLIB')) {
        require_true($memcached->setOption(Memcached::OPT_COMPRESSION_TYPE, Memcached::COMPRESSION_ZLIB), 'selecting zlib compression failed');
    }
    require_same(true, $memcached->getOption(Memcached::OPT_COMPRESSION), 'compression option was not retained');
    if (PHP_INT_SIZE === 4) {
        return;
    }

    $key = 'zlib-rs-memcached-' . bin2hex(random_bytes(4));
    $payload = str_repeat('memcached zlib-rs compression payload ', 2048);
    require_true($memcached->set($key, $payload, 60), 'compressed memcached set failed: ' . $memcached->getResultMessage());
    require_same($payload, $memcached->get($key), 'compressed memcached get round trip failed');
    require_true($memcached->delete($key), 'memcached delete failed: ' . $memcached->getResultMessage());
});

maybe('OAuth', 'oauth signature generation with zlib loaded', function (): void {
    require_true(class_exists('OAuth'), 'OAuth class missing');
    $oauth = new OAuth('consumer-key', 'consumer-secret');
    $oauth->setNonce('zlib-rs-nonce');
    $oauth->setTimestamp('1234567890');
    $signature = $oauth->generateSignature('GET', 'https://example.com/resource', ['encoding' => 'gzip']);
    require_true(is_string($signature) && $signature !== '', 'OAuth signature was empty');
});

maybe('xdebug', 'xdebug loads beside zlib-rs PHP', function (): void {
    require_true(function_exists('xdebug_info'), 'xdebug_info missing');
    require_true(phpversion('xdebug') !== false, 'xdebug version missing');
});

maybe('http', 'pecl_http deflate/inflate encoding streams', function (): void {
    require_true(class_exists('http\\Encoding\\Stream\\Deflate'), 'http Encoding Stream Deflate class missing');
    require_true(class_exists('http\\Encoding\\Stream\\Inflate'), 'http Encoding Stream Inflate class missing');

    $payload = str_repeat('pecl_http zlib-rs encoding payload ', 1024);
    foreach ([
        http\Encoding\Stream\Deflate::TYPE_GZIP,
        http\Encoding\Stream\Deflate::TYPE_ZLIB,
        http\Encoding\Stream\Deflate::TYPE_RAW,
    ] as $type) {
        $compressed = http\Encoding\Stream\Deflate::encode($payload, $type);
        require_true(is_string($compressed) && $compressed !== '', 'http deflate produced no data');
        require_same($payload, http\Encoding\Stream\Inflate::decode($compressed), 'http inflate round trip failed');
    }
});

maybe('solr', 'solr response parsing with zlib loaded', function (): void {
    require_true(class_exists('SolrUtils'), 'SolrUtils class missing');
    require_true(function_exists('solr_get_version'), 'solr_get_version missing');
    require_true((bool) preg_match('/^\d+\.\d+\.\d+/', SolrUtils::getSolrVersion()), 'SolrUtils version was not dotted');
    $query = '+a - q{ } [^test] || && () ^ " ~ * ? : \\ /';
    $escaped = SolrUtils::escapeQueryChars($query);
    require_true($escaped !== $query && str_contains($escaped, '\\+') && str_contains($escaped, '\\:') && str_contains($escaped, '\\/'), 'Solr query escaping changed');
    require_same('"Book Title\\: Apache Solr Server"', SolrUtils::queryPhrase('Book Title: Apache Solr Server'), 'Solr query phrase escaping changed');
});

maybe('ssh2', 'ssh2 compression-capable extension load surface', function (): void {
    require_true(function_exists('ssh2_connect'), 'ssh2_connect missing');
    require_true(function_exists('ssh2_methods_negotiated'), 'ssh2_methods_negotiated missing');
});

maybe('xlswriter', 'xlswriter creates XLSX zip package', function (): void {
    require_true(class_exists('Vtiful\\Kernel\\Excel'), 'Vtiful\\Kernel\\Excel class missing');
    require_true(extension_loaded('zip'), 'zip extension is required to inspect XLSX output');

    $dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'xlswriter-zlib-rs-' . bin2hex(random_bytes(4));
    mkdir($dir);
    $excel = new Vtiful\Kernel\Excel(['path' => $dir]);
    $path = $excel->fileName('compat.xlsx')
        ->header(['name', 'value'])
        ->data([
            ['zlib', 'round-trip'],
            ['payload', str_repeat('A', 256)],
        ])
        ->output();

    require_true(is_file($path), 'xlswriter did not create XLSX file');
    $zip = new ZipArchive();
    require_same(true, $zip->open($path), 'ZipArchive could not open XLSX file');
    require_true($zip->locateName('[Content_Types].xml') !== false, 'XLSX content types missing');
    require_true($zip->locateName('xl/worksheets/sheet1.xml') !== false, 'XLSX worksheet missing');
    $stat = $zip->statName('xl/worksheets/sheet1.xml');
    require_true(is_array($stat) && ($stat['comp_size'] ?? 0) > 0, 'worksheet was not compressed in XLSX package');
    $zip->close();
});

maybe('zip', 'zip deflate archive round trip', function (): void {
    $file = tempnam(sys_get_temp_dir(), 'zip-zlib-rs-') . '.zip';
    $payload = str_repeat('zip extension zlib-rs payload ', 2048);
    $zip = new ZipArchive();
    require_same(true, $zip->open($file, ZipArchive::CREATE | ZipArchive::OVERWRITE), 'failed to create zip');
    require_true($zip->addFromString('payload.txt', $payload), 'failed to add zip entry');
    if (defined('ZipArchive::CM_DEFLATE')) {
        require_true($zip->setCompressionName('payload.txt', ZipArchive::CM_DEFLATE), 'failed to set DEFLATE compression');
    }
    require_true($zip->close(), 'failed to close zip');

    $zip = new ZipArchive();
    require_same(true, $zip->open($file), 'failed to reopen zip');
    $stat = $zip->statName('payload.txt');
    require_true(is_array($stat), 'zip entry stat missing');
    require_same($payload, $zip->getFromName('payload.txt'), 'zip payload round trip failed');
    require_true(($stat['comp_size'] ?? 0) > 0, 'zip compressed size missing');
    $zip->close();
});

$failed = array_values(array_filter($results, static fn(array $result): bool => $result['status'] === 'fail'));

if (isset($options['json'])) {
    file_put_contents((string)$options['json'], json_encode([
        'context' => [
            'mode' => $options['mode'] ?? '',
            'php_target' => $options['php-target'] ?? '',
            'php_run_id' => $options['php-run-id'] ?? '',
            'arch' => $options['arch'] ?? '',
            'ts' => $options['ts'] ?? '',
            'vs' => $options['vs'] ?? '',
            'php_version' => PHP_VERSION,
            'zlib_version' => defined('ZLIB_VERSION') ? ZLIB_VERSION : '',
        ],
        'results' => $results,
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
}

if (isset($options['junit'])) {
    $tests = count($results);
    $failures = count($failed);
    $skips = count(array_filter($results, static fn(array $result): bool => $result['status'] === 'skip'));
    $escape = static fn(string $value): string => htmlspecialchars($value, ENT_XML1 | ENT_QUOTES, 'UTF-8');
    $xml = sprintf('<testsuite tests="%d" failures="%d" skipped="%d">', $tests, $failures, $skips);
    foreach ($results as $result) {
        $xml .= sprintf('<testcase name="%s">', $escape($result['name']));
        if ($result['status'] === 'fail') {
            $xml .= sprintf('<failure message="%s">%s</failure>', $escape($result['message']), $escape($result['message']));
        } elseif ($result['status'] === 'skip') {
            $xml .= sprintf('<skipped>%s</skipped>', $escape($result['message']));
        }
        $xml .= '</testcase>';
    }
    $xml .= '</testsuite>';
    file_put_contents((string)$options['junit'], $xml);
}

exit(count($failed) === 0 ? 0 : 1);
