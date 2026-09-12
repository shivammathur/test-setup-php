<?php
declare(strict_types=1);

error_reporting(E_ALL);
ini_set('display_errors', 'stderr');

final class SuiteFailure extends RuntimeException
{
}

final class TestSuite
{
    /** @var list<array{name: string, callback: callable}> */
    private array $tests = [];

    /** @var list<array{name: string, time: float, failure: ?string}> */
    private array $results = [];

    public function add(string $name, callable $callback): void
    {
        $this->tests[] = ['name' => $name, 'callback' => $callback];
    }

    public function run(?string $junitPath, ?string $jsonPath, array $metadata): int
    {
        $started = microtime(true);
        foreach ($this->tests as $test) {
            $caseStarted = microtime(true);
            $failure = null;
            echo "[ RUN  ] {$test['name']}\n";
            try {
                ($test['callback'])();
                echo "[ PASS ] {$test['name']}\n";
            } catch (Throwable $throwable) {
                $failure = get_class($throwable) . ': ' . $throwable->getMessage() . "\n" . $throwable->getTraceAsString();
                echo "[ FAIL ] {$test['name']}\n{$failure}\n";
            }
            $this->results[] = [
                'name' => $test['name'],
                'time' => microtime(true) - $caseStarted,
                'failure' => $failure,
            ];
        }

        $totalTime = microtime(true) - $started;
        if ($junitPath !== null) {
            $this->writeJunit($junitPath, $totalTime);
        }
        if ($jsonPath !== null) {
            $this->writeJson($jsonPath, $totalTime, $metadata);
        }

        $failures = count(array_filter($this->results, static fn (array $result): bool => $result['failure'] !== null));
        echo sprintf("[ DONE ] %d tests, %d failures, %.3fs\n", count($this->results), $failures, $totalTime);

        return $failures === 0 ? 0 : 1;
    }

    private function writeJunit(string $path, float $totalTime): void
    {
        ensure_dir(dirname($path));
        $failures = count(array_filter($this->results, static fn (array $result): bool => $result['failure'] !== null));
        $xml = [];
        $xml[] = '<?xml version="1.0" encoding="UTF-8"?>';
        $xml[] = sprintf(
            '<testsuite name="winlibs-deps-exhaustive" tests="%d" failures="%d" errors="0" skipped="0" time="%.6f">',
            count($this->results),
            $failures,
            $totalTime
        );
        foreach ($this->results as $result) {
            $xml[] = sprintf(
                '  <testcase classname="winlibs-deps-exhaustive" name="%s" time="%.6f">',
                xml_escape($result['name']),
                $result['time']
            );
            if ($result['failure'] !== null) {
                $xml[] = sprintf('    <failure message="%s">%s</failure>', xml_escape(first_line($result['failure'])), xml_escape($result['failure']));
            }
            $xml[] = '  </testcase>';
        }
        $xml[] = '</testsuite>';
        file_put_contents($path, implode("\n", $xml) . "\n");
    }

    private function writeJson(string $path, float $totalTime, array $metadata): void
    {
        ensure_dir(dirname($path));
        $failures = count(array_filter($this->results, static fn (array $result): bool => $result['failure'] !== null));
        file_put_contents($path, json_encode([
            'metadata' => $metadata,
            'tests' => count($this->results),
            'failures' => $failures,
            'time' => $totalTime,
            'results' => $this->results,
        ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    }
}

function parse_options(array $argv): array
{
    $options = [];
    for ($i = 1; $i < count($argv); $i++) {
        if (!str_starts_with($argv[$i], '--')) {
            continue;
        }
        $key = substr($argv[$i], 2);
        $value = true;
        if (str_contains($key, '=')) {
            [$key, $value] = explode('=', $key, 2);
        } elseif (isset($argv[$i + 1]) && !str_starts_with($argv[$i + 1], '--')) {
            $value = $argv[++$i];
        }
        $options[$key] = $value;
    }
    return $options;
}

function xml_escape(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_XML1, 'UTF-8');
}

function first_line(string $value): string
{
    $line = strtok($value, "\n");
    return $line === false ? $value : $line;
}

function fail_test(string $message): never
{
    throw new SuiteFailure($message);
}

function assert_true(bool $condition, string $message): void
{
    if (!$condition) {
        fail_test($message);
    }
}

function assert_false(bool $condition, string $message): void
{
    if ($condition) {
        fail_test($message);
    }
}

function assert_same(mixed $expected, mixed $actual, string $message): void
{
    if ($expected !== $actual) {
        fail_test($message . ' Expected ' . var_export($expected, true) . ', got ' . var_export($actual, true));
    }
}

function assert_not_same(mixed $unexpected, mixed $actual, string $message): void
{
    if ($unexpected === $actual) {
        fail_test($message . ' Unexpected value ' . var_export($actual, true));
    }
}

function assert_greater_than(int|float $minimum, int|float $actual, string $message): void
{
    if ($actual <= $minimum) {
        fail_test($message . " Expected > {$minimum}, got {$actual}");
    }
}

function assert_at_least(int|float $minimum, int|float $actual, string $message): void
{
    if ($actual < $minimum) {
        fail_test($message . " Expected >= {$minimum}, got {$actual}");
    }
}

function assert_contains(string $needle, string $haystack, string $message): void
{
    if (!str_contains($haystack, $needle)) {
        fail_test($message . " Missing {$needle} in {$haystack}");
    }
}

function assert_array_has_key_string(string $key, array $array, string $message): void
{
    if (!array_key_exists($key, $array)) {
        fail_test($message . " Missing key {$key}");
    }
}

function suite_info(string $message): void
{
    echo "[ INFO ] {$message}\n";
}

function php_target(): string
{
    return (string) ($GLOBALS['suiteOptions']['php-target'] ?? '');
}

function minimum_icu_version_for_target(): string
{
    return match (php_target()) {
        '8.2' => '71.1',
        '8.3' => '72.1',
        default => '77.1',
    };
}

function ffi_api(): FFI
{
    static $ffi = null;
    if (!$ffi instanceof FFI) {
        $ffi = FFI::cdef('typedef char winlibs_ffi_char;');
    }
    return $ffi;
}

function ffi_string_value(mixed $value): string
{
    if ($value instanceof FFI\CData) {
        return FFI::string($value);
    }
    return (string) $value;
}

function assert_near(float $expected, float $actual, float $delta, string $message): void
{
    if (abs($expected - $actual) > $delta) {
        fail_test($message . " Expected {$expected} +/- {$delta}, got {$actual}");
    }
}

function capture_warning(callable $callback): array
{
    $warning = null;
    set_error_handler(static function (int $severity, string $message) use (&$warning): bool {
        $warning = $message;
        return true;
    });
    try {
        $result = $callback();
    } finally {
        restore_error_handler();
    }
    return [$result, $warning];
}

function expect_throwable(string $className, callable $callback, string $message): Throwable
{
    try {
        $callback();
    } catch (Throwable $throwable) {
        if ($throwable instanceof $className) {
            return $throwable;
        }
        fail_test($message . ' Expected ' . $className . ', got ' . get_class($throwable) . ': ' . $throwable->getMessage());
    }
    fail_test($message . ' Expected ' . $className . ', no exception thrown');
}

function run_php_code_with_stdin(string $code, string $stdin): array
{
    $ini = getenv('WINLIBS_QA_PHP_INI');
    $command = is_string($ini) && $ini !== ''
        ? [PHP_BINARY, '-c', $ini, '-r', $code]
        : [PHP_BINARY, '-r', $code];
    $process = proc_open($command, [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ], $pipes);
    if (!is_resource($process)) {
        fail_test('Unable to start child PHP process');
    }
    fwrite($pipes[0], $stdin);
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    return [$exitCode, (string) $stdout, (string) $stderr];
}

function ensure_dir(string $path): void
{
    if (!is_dir($path) && !mkdir($path, 0777, true) && !is_dir($path)) {
        fail_test("Unable to create directory {$path}");
    }
}

function make_temp_dir(string $prefix): string
{
    $path = sys_get_temp_dir() . DIRECTORY_SEPARATOR . $prefix . '-' . getmypid() . '-' . bin2hex(random_bytes(4));
    ensure_dir($path);
    return $path;
}

function rrmdir(string $path): void
{
    if (!is_dir($path)) {
        return;
    }
    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($iterator as $item) {
        if ($item->isDir()) {
            rmdir($item->getPathname());
        } else {
            unlink($item->getPathname());
        }
    }
    rmdir($path);
}

function require_extension_loaded(string $extension): void
{
    assert_true(extension_loaded($extension), "Required extension {$extension} is not loaded");
}

function internal_functions_with_prefix(string $prefix): array
{
    $functions = get_defined_functions();
    $internal = $functions['internal'] ?? [];
    $matches = array_values(array_filter(
        $internal,
        static fn (string $function): bool => str_starts_with($function, $prefix)
    ));
    sort($matches);
    return $matches;
}

function assert_internal_function_manifest(string $label, string $prefix, array $required, array $optional = []): void
{
    $actual = internal_functions_with_prefix($prefix);
    sort($required);
    sort($optional);
    $allowed = array_values(array_unique(array_merge($required, $optional)));
    sort($allowed);

    $missing = array_values(array_diff($required, $actual));
    $unexpected = array_values(array_diff($actual, $allowed));
    assert_same([], $missing, "{$label} should expose every required manual/stub function");
    assert_same([], $unexpected, "{$label} should not expose unaccounted userland functions");
}

function assert_class_method_manifest(string $className, array $required, array $optional = []): void
{
    assert_true(class_exists($className), "{$className} should exist");
    $methods = array_map(
        static fn (ReflectionMethod $method): string => $method->getName(),
        (new ReflectionClass($className))->getMethods()
    );
    sort($methods);
    sort($required);
    sort($optional);
    $allowed = array_values(array_unique(array_merge($required, $optional)));
    sort($allowed);

    $missing = array_values(array_diff($required, $methods));
    $unexpected = array_values(array_diff($methods, $allowed));
    assert_same([], $missing, "{$className} should expose every required manual/stub method");
    assert_same([], $unexpected, "{$className} should not expose unaccounted methods");
}

function assert_constants_defined(array $constants, string $label): void
{
    foreach ($constants as $constant) {
        assert_true(defined($constant), "{$label} constant {$constant} should be defined");
    }
}

function normalize_header_name(string $header): string
{
    return strtolower(str_replace('_', '-', $header));
}

function build_dir(): string
{
    $dir = getenv('WINLIBS_QA_BUILD_DIR');
    assert_true(is_string($dir) && $dir !== '' && is_dir($dir), 'WINLIBS_QA_BUILD_DIR must point at the extracted PHP build');
    return $dir;
}

function find_build_file(string $pattern): ?string
{
    $root = build_dir();
    $regex = '/^' . str_replace('\\*', '.*', preg_quote($pattern, '/')) . '$/i';
    $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));
    foreach ($iterator as $file) {
        if ($file->isFile() && preg_match($regex, $file->getFilename()) === 1) {
            return $file->getPathname();
        }
    }
    return null;
}

final class LocalHttpServer
{
    private string $root;
    private string $script;
    private string $portFile;
    private $process = null;
    /** @var array<int, resource> */
    private array $pipes = [];
    private string $baseUrl;

    public function __construct()
    {
        $this->root = make_temp_dir('winlibs-curl-server');
        $this->script = $this->root . DIRECTORY_SEPARATOR . 'server.php';
        $this->portFile = $this->root . DIRECTORY_SEPARATOR . 'port.txt';
        file_put_contents($this->script, self::serverCode());
    }

    public function start(): string
    {
        $ini = getenv('WINLIBS_QA_PHP_INI');
        $command = is_string($ini) && $ini !== ''
            ? [PHP_BINARY, '-c', $ini, $this->script, $this->portFile]
            : [PHP_BINARY, $this->script, $this->portFile];
        $this->process = proc_open($command, [
            0 => ['pipe', 'r'],
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ], $this->pipes, $this->root);
        if (!is_resource($this->process)) {
            fail_test('Unable to start local HTTP server process');
        }

        $deadline = microtime(true) + 10.0;
        while (microtime(true) < $deadline) {
            if (is_file($this->portFile)) {
                $port = trim((string) file_get_contents($this->portFile));
                if ($port !== '') {
                    $this->baseUrl = 'http://127.0.0.1:' . $port;
                    return $this->baseUrl;
                }
            }
            usleep(100000);
        }
        fail_test('Local HTTP server did not publish a port');
    }

    public function stop(): void
    {
        if (isset($this->baseUrl)) {
            $ch = curl_init($this->baseUrl . '/shutdown');
            curl_setopt_array($ch, [
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT => 2,
            ]);
            @curl_exec($ch);
            curl_close_if_needed($ch);
        }
        if (is_resource($this->process)) {
            @proc_terminate($this->process);
            @proc_close($this->process);
        }
        foreach ($this->pipes as $pipe) {
            if (is_resource($pipe)) {
                @fclose($pipe);
            }
        }
        rrmdir($this->root);
    }

    private static function serverCode(): string
    {
        return <<<'PHP'
<?php
declare(strict_types=1);

$portFile = $argv[1];
$server = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
if (!$server) {
    file_put_contents($portFile, 'ERROR ' . $errstr);
    exit(1);
}
$name = stream_socket_get_name($server, false);
$port = (int) substr(strrchr($name, ':'), 1);
file_put_contents($portFile, (string) $port);

function read_request($conn): array
{
    $buffer = '';
    while (!str_contains($buffer, "\r\n\r\n") && !feof($conn)) {
        $buffer .= fread($conn, 4096);
    }
    [$head, $body] = array_pad(explode("\r\n\r\n", $buffer, 2), 2, '');
    $lines = explode("\r\n", $head);
    $request = array_shift($lines) ?: 'GET / HTTP/1.1';
    [$method, $target] = array_pad(explode(' ', $request, 3), 3, '');
    $headers = [];
    foreach ($lines as $line) {
        if (!str_contains($line, ':')) {
            continue;
        }
        [$name, $value] = explode(':', $line, 2);
        $headers[strtolower($name)] = trim($value);
    }
    $length = isset($headers['content-length']) ? (int) $headers['content-length'] : 0;
    while (strlen($body) < $length && !feof($conn)) {
        $body .= fread($conn, $length - strlen($body));
    }
    return [$method, $target, $headers, $body];
}

function respond($conn, int $status, array $headers, string $body): void
{
    $phrases = [200 => 'OK', 201 => 'Created', 302 => 'Found', 404 => 'Not Found'];
    $headers['Content-Length'] = (string) strlen($body);
    $headers['Connection'] = 'close';
    fwrite($conn, "HTTP/1.1 {$status} " . ($phrases[$status] ?? 'OK') . "\r\n");
    foreach ($headers as $name => $value) {
        fwrite($conn, "{$name}: {$value}\r\n");
    }
    fwrite($conn, "\r\n{$body}");
}

while ($conn = @stream_socket_accept($server, 30)) {
    [$method, $target, $headers, $body] = read_request($conn);
    $path = parse_url($target, PHP_URL_PATH) ?: '/';
    if ($path === '/shutdown') {
        respond($conn, 200, ['Content-Type' => 'text/plain'], 'bye');
        fclose($conn);
        break;
    }
    if ($path === '/redirect') {
        respond($conn, 302, ['Location' => '/json?redirected=1'], '');
    } elseif ($path === '/gzip') {
        respond($conn, 200, ['Content-Type' => 'text/plain', 'Content-Encoding' => 'gzip'], base64_decode('H4sIAAAAAAAAE0vOzy0oSi0uTk1RAFIF+XnFqQpJ+SmVAHRtJ8sYAAAA'));
    } elseif ($path === '/cookie') {
        respond($conn, 200, ['Content-Type' => 'application/json', 'Set-Cookie' => 'winlibs=curl; Path=/'], json_encode(['cookie' => $headers['cookie'] ?? '']));
    } elseif ($path === '/upload') {
        respond($conn, 201, ['Content-Type' => 'application/json'], json_encode(['method' => $method, 'length' => strlen($body), 'sha256' => hash('sha256', $body)]));
    } elseif ($path === '/headers') {
        respond($conn, 200, ['Content-Type' => 'application/json'], json_encode(['headers' => $headers]));
    } elseif ($path === '/json') {
        respond($conn, 200, ['Content-Type' => 'application/json'], json_encode([
            'method' => $method,
            'target' => $target,
            'headers' => $headers,
            'body' => $body,
        ]));
    } else {
        respond($conn, 404, ['Content-Type' => 'text/plain'], 'not found');
    }
    fclose($conn);
}
PHP;
    }
}

function curl_exec_checked(CurlHandle $ch): string
{
    $result = curl_exec($ch);
    if ($result === false) {
        fail_test('curl_exec failed: ' . curl_errno($ch) . ' ' . curl_error($ch));
    }
    return (string) $result;
}

function curl_close_if_needed(CurlHandle $ch): void
{
    if (PHP_VERSION_ID < 80500) {
        curl_close($ch);
    }
}

function curl_share_close_if_needed(CurlShareHandle $share): void
{
    if (PHP_VERSION_ID < 80500) {
        curl_share_close($share);
    }
}

function assert_curl_userland_manifest(): void
{
    assert_internal_function_manifest('curl', 'curl_', [
        'curl_close',
        'curl_copy_handle',
        'curl_errno',
        'curl_error',
        'curl_escape',
        'curl_exec',
        'curl_file_create',
        'curl_getinfo',
        'curl_init',
        'curl_multi_add_handle',
        'curl_multi_close',
        'curl_multi_errno',
        'curl_multi_exec',
        'curl_multi_getcontent',
        'curl_multi_info_read',
        'curl_multi_init',
        'curl_multi_remove_handle',
        'curl_multi_select',
        'curl_multi_setopt',
        'curl_multi_strerror',
        'curl_pause',
        'curl_reset',
        'curl_setopt',
        'curl_setopt_array',
        'curl_share_close',
        'curl_share_errno',
        'curl_share_init',
        'curl_share_setopt',
        'curl_share_strerror',
        'curl_strerror',
        'curl_unescape',
        'curl_upkeep',
        'curl_version',
    ], [
        'curl_multi_get_handles',
        'curl_share_init_persistent',
    ]);

    assert_class_method_manifest('CurlHandle', []);
    assert_class_method_manifest('CurlMultiHandle', []);
    assert_class_method_manifest('CurlShareHandle', []);
    if (class_exists('CurlSharePersistentHandle')) {
        assert_class_method_manifest('CurlSharePersistentHandle', []);
    }
    assert_class_method_manifest(CURLFile::class, [
        '__construct',
        'getFilename',
        'getMimeType',
        'getPostFilename',
        'setMimeType',
        'setPostFilename',
    ]);
    assert_class_method_manifest(CURLStringFile::class, ['__construct']);

    assert_constants_defined([
        'CURLE_OK',
        'CURLM_OK',
        'CURLINFO_EFFECTIVE_URL',
        'CURLINFO_HEADER_OUT',
        'CURLINFO_HEADER_SIZE',
        'CURLINFO_RESPONSE_CODE',
        'CURL_LOCK_DATA_COOKIE',
        'CURL_LOCK_DATA_DNS',
        'CURL_LOCK_DATA_SSL_SESSION',
        'CURLPAUSE_CONT',
        'CURLSHOPT_SHARE',
        'CURLSHOPT_UNSHARE',
        'CURLOPT_COOKIEFILE',
        'CURLOPT_COOKIEJAR',
        'CURLOPT_ENCODING',
        'CURLOPT_FILE',
        'CURLOPT_FOLLOWLOCATION',
        'CURLOPT_HEADER',
        'CURLOPT_HTTPHEADER',
        'CURLOPT_POST',
        'CURLOPT_POSTFIELDS',
        'CURLOPT_RETURNTRANSFER',
        'CURLOPT_SHARE',
        'CURLOPT_TIMEOUT',
        'CURLOPT_URL',
    ], 'curl');
}

function assert_ffi_userland_manifest(): void
{
    assert_class_method_manifest(FFI::class, [
        'addr',
        'alignof',
        'arrayType',
        'cast',
        'cdef',
        'free',
        'isNull',
        'load',
        'memcmp',
        'memcpy',
        'memset',
        'new',
        'scope',
        'sizeof',
        'string',
        'type',
        'typeof',
    ]);
    assert_class_method_manifest(FFI\CData::class, []);
    assert_class_method_manifest(FFI\CType::class, [
        'getAlignment',
        'getArrayElementType',
        'getArrayLength',
        'getAttributes',
        'getEnumKind',
        'getFuncABI',
        'getFuncReturnType',
        'getKind',
        'getName',
        'getPointerType',
        'getSize',
        'getStructFieldNames',
        'getStructFieldOffset',
        'getStructFieldType',
    ], [
        'getFuncParameterCount',
        'getFuncParameterType',
    ]);
    assert_constants_defined([
        'FFI::__BIGGEST_ALIGNMENT__',
        'FFI\CType::TYPE_ARRAY',
        'FFI\CType::TYPE_ENUM',
        'FFI\CType::TYPE_FUNC',
        'FFI\CType::TYPE_POINTER',
        'FFI\CType::TYPE_STRUCT',
        'FFI\CType::ABI_DEFAULT',
    ], 'FFI');
}

function assert_enchant_userland_manifest(): void
{
    assert_internal_function_manifest('enchant', 'enchant_', [
        'enchant_broker_describe',
        'enchant_broker_dict_exists',
        'enchant_broker_free',
        'enchant_broker_free_dict',
        'enchant_broker_get_dict_path',
        'enchant_broker_get_error',
        'enchant_broker_init',
        'enchant_broker_list_dicts',
        'enchant_broker_request_dict',
        'enchant_broker_request_pwl_dict',
        'enchant_broker_set_dict_path',
        'enchant_broker_set_ordering',
        'enchant_dict_add',
        'enchant_dict_add_to_personal',
        'enchant_dict_add_to_session',
        'enchant_dict_check',
        'enchant_dict_describe',
        'enchant_dict_get_error',
        'enchant_dict_is_added',
        'enchant_dict_is_in_session',
        'enchant_dict_quick_check',
        'enchant_dict_store_replacement',
        'enchant_dict_suggest',
    ], [
        'enchant_dict_remove',
        'enchant_dict_remove_from_session',
    ]);
    assert_class_method_manifest('EnchantBroker', []);
    assert_class_method_manifest('EnchantDictionary', []);
    assert_constants_defined(['ENCHANT_MYSPELL', 'ENCHANT_ISPELL'], 'enchant');
    if (defined('LIBENCHANT_VERSION')) {
        assert_not_same('', (string) constant('LIBENCHANT_VERSION'), 'LIBENCHANT_VERSION should be populated');
    }
}

function assert_gd_jpeg_userland_manifest(): void
{
    foreach ([
        'gd_info',
        'getimagesize',
        'getimagesizefromstring',
        'image_type_to_extension',
        'image_type_to_mime_type',
        'imagecreatefromjpeg',
        'imagecreatefromstring',
        'imagejpeg',
        'imagetypes',
    ] as $function) {
        assert_true(function_exists($function), "{$function} should exist for JPEG coverage");
    }
    if (extension_loaded('exif')) {
        assert_true(function_exists('exif_imagetype'), 'exif_imagetype should exist when exif is loaded');
    }
    assert_constants_defined(['IMG_JPG', 'IMG_JPEG', 'IMAGETYPE_JPEG'], 'gd/jpeg');
}

function assert_tidy_userland_manifest(): void
{
    assert_internal_function_manifest('tidy', 'tidy_', [
        'tidy_access_count',
        'tidy_clean_repair',
        'tidy_config_count',
        'tidy_diagnose',
        'tidy_error_count',
        'tidy_get_body',
        'tidy_get_config',
        'tidy_get_error_buffer',
        'tidy_get_head',
        'tidy_get_html',
        'tidy_get_html_ver',
        'tidy_get_opt_doc',
        'tidy_get_output',
        'tidy_get_root',
        'tidy_get_release',
        'tidy_get_status',
        'tidy_getopt',
        'tidy_is_xhtml',
        'tidy_is_xml',
        'tidy_parse_file',
        'tidy_parse_string',
        'tidy_repair_file',
        'tidy_repair_string',
        'tidy_warning_count',
    ]);
    assert_class_method_manifest(tidy::class, [
        '__construct',
        'body',
        'cleanRepair',
        'diagnose',
        'getConfig',
        'getHtmlVer',
        'getOpt',
        'getOptDoc',
        'getRelease',
        'getStatus',
        'head',
        'html',
        'isXhtml',
        'isXml',
        'parseFile',
        'parseString',
        'repairFile',
        'repairString',
        'root',
    ]);
    assert_class_method_manifest(tidyNode::class, [
        '__construct',
        'getParent',
        'hasChildren',
        'hasSiblings',
        'isAsp',
        'isComment',
        'isHtml',
        'isJste',
        'isPhp',
        'isText',
    ], [
        'getNextSibling',
        'getPreviousSibling',
    ]);
    assert_constants_defined([
        'TIDY_NODETYPE_ROOT',
        'TIDY_NODETYPE_TEXT',
        'TIDY_TAG_BODY',
        'TIDY_TAG_HEAD',
        'TIDY_TAG_HTML',
        'TIDY_TAG_P',
        'TIDY_TAG_TITLE',
    ], 'tidy');
}

function assert_readline_userland_manifest(): void
{
    $functions = get_defined_functions();
    $internal = $functions['internal'] ?? [];
    $actual = array_values(array_filter(
        $internal,
        static fn (string $function): bool => $function === 'readline' || str_starts_with($function, 'readline_')
    ));
    sort($actual);
    $required = [
        'readline',
        'readline_add_history',
        'readline_clear_history',
        'readline_completion_function',
        'readline_info',
        'readline_read_history',
        'readline_write_history',
    ];
    $optional = [
        'readline_callback_handler_install',
        'readline_callback_handler_remove',
        'readline_callback_read_char',
        'readline_list_history',
        'readline_on_new_line',
        'readline_redisplay',
    ];
    sort($required);
    sort($optional);
    $allowed = array_values(array_unique(array_merge($required, $optional)));
    sort($allowed);
    assert_same([], array_values(array_diff($required, $actual)), 'readline should expose every required manual/stub function');
    assert_same([], array_values(array_diff($actual, $allowed)), 'readline should not expose unaccounted userland functions');
    assert_constants_defined(['READLINE_LIB'], 'readline');
    assert_not_same('', (string) constant('READLINE_LIB'), 'READLINE_LIB should be populated');
}

function intl_break_iterator_methods(): array
{
    return [
        '__construct',
        'createCharacterInstance',
        'createCodePointInstance',
        'createLineInstance',
        'createSentenceInstance',
        'createTitleInstance',
        'createWordInstance',
        'current',
        'first',
        'following',
        'getErrorCode',
        'getErrorMessage',
        'getIterator',
        'getLocale',
        'getPartsIterator',
        'getText',
        'isBoundary',
        'last',
        'next',
        'preceding',
        'previous',
        'setText',
    ];
}

function intl_calendar_methods(): array
{
    return [
        '__construct',
        'add',
        'after',
        'before',
        'clear',
        'createInstance',
        'equals',
        'fieldDifference',
        'fromDateTime',
        'get',
        'getActualMaximum',
        'getActualMinimum',
        'getAvailableLocales',
        'getDayOfWeekType',
        'getErrorCode',
        'getErrorMessage',
        'getFirstDayOfWeek',
        'getGreatestMinimum',
        'getKeywordValuesForLocale',
        'getLeastMaximum',
        'getLocale',
        'getMaximum',
        'getMinimalDaysInFirstWeek',
        'getMinimum',
        'getNow',
        'getRepeatedWallTimeOption',
        'getSkippedWallTimeOption',
        'getTime',
        'getTimeZone',
        'getType',
        'getWeekendTransition',
        'inDaylightTime',
        'isEquivalentTo',
        'isLenient',
        'isSet',
        'isWeekend',
        'roll',
        'set',
        'setFirstDayOfWeek',
        'setLenient',
        'setMinimalDaysInFirstWeek',
        'setRepeatedWallTimeOption',
        'setSkippedWallTimeOption',
        'setTime',
        'setTimeZone',
        'toDateTime',
    ];
}

function intl_calendar_optional_methods(): array
{
    return [
        'setDate',
        'setDateTime',
    ];
}

function assert_intl_userland_manifest(): void
{
    assert_internal_function_manifest('intl common', 'intl_', [
        'intl_error_name',
        'intl_get_error_code',
        'intl_get_error_message',
        'intl_is_failure',
    ]);
    assert_internal_function_manifest('intl calendar', 'intlcal_', [
        'intlcal_add',
        'intlcal_after',
        'intlcal_before',
        'intlcal_clear',
        'intlcal_create_instance',
        'intlcal_equals',
        'intlcal_field_difference',
        'intlcal_from_date_time',
        'intlcal_get',
        'intlcal_get_actual_maximum',
        'intlcal_get_actual_minimum',
        'intlcal_get_available_locales',
        'intlcal_get_day_of_week_type',
        'intlcal_get_error_code',
        'intlcal_get_error_message',
        'intlcal_get_first_day_of_week',
        'intlcal_get_greatest_minimum',
        'intlcal_get_keyword_values_for_locale',
        'intlcal_get_least_maximum',
        'intlcal_get_locale',
        'intlcal_get_maximum',
        'intlcal_get_minimal_days_in_first_week',
        'intlcal_get_minimum',
        'intlcal_get_now',
        'intlcal_get_repeated_wall_time_option',
        'intlcal_get_skipped_wall_time_option',
        'intlcal_get_time',
        'intlcal_get_time_zone',
        'intlcal_get_type',
        'intlcal_get_weekend_transition',
        'intlcal_in_daylight_time',
        'intlcal_is_equivalent_to',
        'intlcal_is_lenient',
        'intlcal_is_set',
        'intlcal_is_weekend',
        'intlcal_roll',
        'intlcal_set',
        'intlcal_set_first_day_of_week',
        'intlcal_set_lenient',
        'intlcal_set_minimal_days_in_first_week',
        'intlcal_set_repeated_wall_time_option',
        'intlcal_set_skipped_wall_time_option',
        'intlcal_set_time',
        'intlcal_set_time_zone',
        'intlcal_to_date_time',
    ]);
    assert_internal_function_manifest('intl gregorian calendar', 'intlgregcal_', [
        'intlgregcal_create_instance',
        'intlgregcal_get_gregorian_change',
        'intlgregcal_is_leap_year',
        'intlgregcal_set_gregorian_change',
    ]);
    assert_internal_function_manifest('intl collator', 'collator_', [
        'collator_asort',
        'collator_compare',
        'collator_create',
        'collator_get_attribute',
        'collator_get_error_code',
        'collator_get_error_message',
        'collator_get_locale',
        'collator_get_sort_key',
        'collator_get_strength',
        'collator_set_attribute',
        'collator_set_strength',
        'collator_sort',
        'collator_sort_with_sort_keys',
    ]);
    assert_internal_function_manifest('intl date formatter', 'datefmt_', [
        'datefmt_create',
        'datefmt_format',
        'datefmt_format_object',
        'datefmt_get_calendar',
        'datefmt_get_calendar_object',
        'datefmt_get_datetype',
        'datefmt_get_error_code',
        'datefmt_get_error_message',
        'datefmt_get_locale',
        'datefmt_get_pattern',
        'datefmt_get_timetype',
        'datefmt_get_timezone',
        'datefmt_get_timezone_id',
        'datefmt_is_lenient',
        'datefmt_localtime',
        'datefmt_parse',
        'datefmt_set_calendar',
        'datefmt_set_lenient',
        'datefmt_set_pattern',
        'datefmt_set_timezone',
    ]);
    assert_internal_function_manifest('intl number formatter', 'numfmt_', [
        'numfmt_create',
        'numfmt_format',
        'numfmt_format_currency',
        'numfmt_get_attribute',
        'numfmt_get_error_code',
        'numfmt_get_error_message',
        'numfmt_get_locale',
        'numfmt_get_pattern',
        'numfmt_get_symbol',
        'numfmt_get_text_attribute',
        'numfmt_parse',
        'numfmt_parse_currency',
        'numfmt_set_attribute',
        'numfmt_set_pattern',
        'numfmt_set_symbol',
        'numfmt_set_text_attribute',
    ]);
    assert_internal_function_manifest('intl message formatter', 'msgfmt_', [
        'msgfmt_create',
        'msgfmt_format',
        'msgfmt_format_message',
        'msgfmt_get_error_code',
        'msgfmt_get_error_message',
        'msgfmt_get_locale',
        'msgfmt_get_pattern',
        'msgfmt_parse',
        'msgfmt_parse_message',
        'msgfmt_set_pattern',
    ]);
    assert_internal_function_manifest('intl grapheme', 'grapheme_', [
        'grapheme_extract',
        'grapheme_stripos',
        'grapheme_stristr',
        'grapheme_strlen',
        'grapheme_strpos',
        'grapheme_strripos',
        'grapheme_strrpos',
        'grapheme_strstr',
        'grapheme_substr',
    ], [
        'grapheme_levenshtein',
        'grapheme_str_split',
        'grapheme_strrev',
    ]);
    assert_internal_function_manifest('intl locale', 'locale_', [
        'locale_accept_from_http',
        'locale_canonicalize',
        'locale_compose',
        'locale_filter_matches',
        'locale_get_all_variants',
        'locale_get_default',
        'locale_get_display_language',
        'locale_get_display_name',
        'locale_get_display_region',
        'locale_get_display_script',
        'locale_get_display_variant',
        'locale_get_keywords',
        'locale_get_primary_language',
        'locale_get_region',
        'locale_get_script',
        'locale_lookup',
        'locale_parse',
        'locale_set_default',
    ], [
        'locale_add_likely_subtags',
        'locale_is_right_to_left',
        'locale_minimize_subtags',
    ]);
    assert_internal_function_manifest('intl normalizer', 'normalizer_', [
        'normalizer_get_raw_decomposition',
        'normalizer_is_normalized',
        'normalizer_normalize',
    ]);
    assert_internal_function_manifest('intl resource bundle', 'resourcebundle_', [
        'resourcebundle_count',
        'resourcebundle_create',
        'resourcebundle_get',
        'resourcebundle_get_error_code',
        'resourcebundle_get_error_message',
        'resourcebundle_locales',
    ]);
    assert_internal_function_manifest('intl timezone', 'intltz_', [
        'intltz_count_equivalent_ids',
        'intltz_create_default',
        'intltz_create_enumeration',
        'intltz_create_time_zone',
        'intltz_create_time_zone_id_enumeration',
        'intltz_from_date_time_zone',
        'intltz_get_canonical_id',
        'intltz_get_display_name',
        'intltz_get_dst_savings',
        'intltz_get_equivalent_id',
        'intltz_get_error_code',
        'intltz_get_error_message',
        'intltz_get_gmt',
        'intltz_get_id',
        'intltz_get_id_for_windows_id',
        'intltz_get_offset',
        'intltz_get_raw_offset',
        'intltz_get_region',
        'intltz_get_tz_data_version',
        'intltz_get_unknown',
        'intltz_get_windows_id',
        'intltz_has_same_rules',
        'intltz_to_date_time_zone',
        'intltz_use_daylight_time',
    ], [
        'intltz_get_iana_id',
    ]);
    assert_internal_function_manifest('intl transliterator', 'transliterator_', [
        'transliterator_create',
        'transliterator_create_from_rules',
        'transliterator_create_inverse',
        'transliterator_get_error_code',
        'transliterator_get_error_message',
        'transliterator_list_ids',
        'transliterator_transliterate',
    ]);
    assert_internal_function_manifest('intl idn', 'idn_', [
        'idn_to_ascii',
        'idn_to_utf8',
    ]);

    assert_class_method_manifest(Collator::class, ['__construct', 'asort', 'compare', 'create', 'getAttribute', 'getErrorCode', 'getErrorMessage', 'getLocale', 'getSortKey', 'getStrength', 'setAttribute', 'setStrength', 'sort', 'sortWithSortKeys']);
    assert_class_method_manifest(NumberFormatter::class, ['__construct', 'create', 'format', 'formatCurrency', 'getAttribute', 'getErrorCode', 'getErrorMessage', 'getLocale', 'getPattern', 'getSymbol', 'getTextAttribute', 'parse', 'parseCurrency', 'setAttribute', 'setPattern', 'setSymbol', 'setTextAttribute']);
    assert_class_method_manifest(IntlDateFormatter::class, ['__construct', 'create', 'format', 'formatObject', 'getCalendar', 'getCalendarObject', 'getDateType', 'getErrorCode', 'getErrorMessage', 'getLocale', 'getPattern', 'getTimeType', 'getTimeZone', 'getTimeZoneId', 'isLenient', 'localtime', 'parse', 'setCalendar', 'setLenient', 'setPattern', 'setTimeZone'], ['parseToCalendar']);
    assert_class_method_manifest(IntlDatePatternGenerator::class, ['__construct', 'create', 'getBestPattern']);
    assert_class_method_manifest(MessageFormatter::class, ['__construct', 'create', 'format', 'formatMessage', 'getErrorCode', 'getErrorMessage', 'getLocale', 'getPattern', 'parse', 'parseMessage', 'setPattern']);
    assert_class_method_manifest(Normalizer::class, ['getRawDecomposition', 'isNormalized', 'normalize']);
    assert_class_method_manifest(Locale::class, ['acceptFromHttp', 'canonicalize', 'composeLocale', 'filterMatches', 'getAllVariants', 'getDefault', 'getDisplayLanguage', 'getDisplayName', 'getDisplayRegion', 'getDisplayScript', 'getDisplayVariant', 'getKeywords', 'getPrimaryLanguage', 'getRegion', 'getScript', 'lookup', 'parseLocale', 'setDefault'], ['addLikelySubtags', 'isRightToLeft', 'minimizeSubtags']);
    assert_class_method_manifest(IntlCalendar::class, intl_calendar_methods(), intl_calendar_optional_methods());
    assert_class_method_manifest(IntlGregorianCalendar::class, array_values(array_unique(array_merge(intl_calendar_methods(), ['getGregorianChange', 'isLeapYear', 'setGregorianChange']))), array_values(array_unique(array_merge(intl_calendar_optional_methods(), ['createFromDate', 'createFromDateTime']))));
    assert_class_method_manifest(IntlTimeZone::class, ['__construct', 'countEquivalentIDs', 'createDefault', 'createEnumeration', 'createTimeZone', 'createTimeZoneIDEnumeration', 'fromDateTimeZone', 'getCanonicalID', 'getDSTSavings', 'getDisplayName', 'getEquivalentID', 'getErrorCode', 'getErrorMessage', 'getGMT', 'getID', 'getIDForWindowsID', 'getOffset', 'getRawOffset', 'getRegion', 'getTZDataVersion', 'getUnknown', 'getWindowsID', 'hasSameRules', 'toDateTimeZone', 'useDaylightTime'], ['getIanaID']);
    assert_class_method_manifest(ResourceBundle::class, ['__construct', 'count', 'create', 'get', 'getErrorCode', 'getErrorMessage', 'getIterator', 'getLocales']);
    assert_class_method_manifest(Transliterator::class, ['__construct', 'create', 'createFromRules', 'createInverse', 'getErrorCode', 'getErrorMessage', 'listIDs', 'transliterate']);
    assert_class_method_manifest(Spoofchecker::class, ['__construct', 'areConfusable', 'isSuspicious', 'setAllowedLocales', 'setChecks', 'setRestrictionLevel'], ['setAllowedChars']);
    assert_class_method_manifest(IntlBreakIterator::class, intl_break_iterator_methods());
    assert_class_method_manifest(IntlRuleBasedBreakIterator::class, array_values(array_unique(array_merge(intl_break_iterator_methods(), ['getBinaryRules', 'getRuleStatus', 'getRuleStatusVec', 'getRules']))));
    assert_class_method_manifest(IntlCodePointBreakIterator::class, array_values(array_unique(array_merge(array_diff(intl_break_iterator_methods(), ['__construct']), ['getLastCodePoint']))));
    assert_class_method_manifest(IntlIterator::class, ['current', 'key', 'next', 'rewind', 'valid']);
    assert_class_method_manifest(IntlPartsIterator::class, ['current', 'getBreakIterator', 'getRuleStatus', 'key', 'next', 'rewind', 'valid']);
    assert_class_method_manifest(UConverter::class, ['__construct', 'convert', 'fromUCallback', 'getAliases', 'getAvailable', 'getDestinationEncoding', 'getDestinationType', 'getErrorCode', 'getErrorMessage', 'getSourceEncoding', 'getSourceType', 'getStandards', 'getSubstChars', 'reasonText', 'setDestinationEncoding', 'setSourceEncoding', 'setSubstChars', 'toUCallback', 'transcode']);
    assert_class_method_manifest(IntlChar::class, ['charAge', 'charDigitValue', 'charDirection', 'charFromName', 'charMirror', 'charName', 'charType', 'chr', 'digit', 'enumCharNames', 'enumCharTypes', 'foldCase', 'forDigit', 'getBidiPairedBracket', 'getBlockCode', 'getCombiningClass', 'getFC_NFKC_Closure', 'getIntPropertyMaxValue', 'getIntPropertyMinValue', 'getIntPropertyValue', 'getNumericValue', 'getPropertyEnum', 'getPropertyName', 'getPropertyValueEnum', 'getPropertyValueName', 'getUnicodeVersion', 'hasBinaryProperty', 'isalnum', 'isalpha', 'isbase', 'isblank', 'iscntrl', 'isdefined', 'isdigit', 'isgraph', 'isIDIgnorable', 'isIDPart', 'isIDStart', 'isISOControl', 'isJavaIDPart', 'isJavaIDStart', 'isJavaSpaceChar', 'islower', 'isMirrored', 'isprint', 'ispunct', 'isspace', 'istitle', 'isUAlphabetic', 'isULowercase', 'isupper', 'isUUppercase', 'isUWhiteSpace', 'isWhitespace', 'isxdigit', 'ord', 'tolower', 'totitle', 'toupper']);
}

function create_reference_image(int $width = 96, int $height = 64): GdImage
{
    $image = imagecreatetruecolor($width, $height);
    for ($y = 0; $y < $height; $y++) {
        for ($x = 0; $x < $width; $x++) {
            $color = imagecolorallocate($image, ($x * 3) % 256, ($y * 5) % 256, (($x + $y) * 2) % 256);
            imagesetpixel($image, $x, $y, $color);
        }
    }
    imagefilledrectangle($image, 4, 4, 28, 24, imagecolorallocate($image, 240, 20, 20));
    imagefilledellipse($image, 66, 38, 36, 24, imagecolorallocate($image, 20, 210, 60));
    imageline($image, 0, $height - 1, $width - 1, 0, imagecolorallocate($image, 30, 70, 240));
    return $image;
}

function jpeg_markers(string $bytes): array
{
    $markers = [];
    $length = strlen($bytes);
    for ($i = 0; $i < $length - 1; $i++) {
        if (ord($bytes[$i]) === 0xFF && ord($bytes[$i + 1]) !== 0x00 && ord($bytes[$i + 1]) !== 0xFF) {
            $markers[] = ord($bytes[$i + 1]);
        }
    }
    return $markers;
}

function find_tidy_node(object $node, callable $predicate): ?object
{
    if ($predicate($node)) {
        return $node;
    }
    $children = $node->child ?? [];
    if (!is_array($children)) {
        return null;
    }
    foreach ($children as $child) {
        if (!is_object($child)) {
            continue;
        }
        $match = find_tidy_node($child, $predicate);
        if ($match !== null) {
            return $match;
        }
    }
    return null;
}

function test_environment(array $options): void
{
    assert_same('cli', PHP_SAPI, 'Suite must run on CLI');
    assert_same('Windows', PHP_OS_FAMILY, 'Suite must run on Windows');
    assert_true(is_file(PHP_BINARY), 'PHP_BINARY must point at php.exe');
    assert_same(($options['ts'] ?? '') === 'ts', (bool) PHP_ZTS, 'Thread-safety must match artifact name');
    assert_same(($options['arch'] ?? '') === 'x64' ? 8 : 4, PHP_INT_SIZE, 'Pointer size must match artifact architecture');
    foreach (['curl', 'FFI', 'gd', 'enchant', 'intl', 'tidy'] as $extension) {
        assert_true(extension_loaded($extension), "Extension {$extension} should be loaded");
    }
    assert_contains(build_dir(), getenv('PATH') ?: '', 'PATH should include extracted PHP build directory');
    assert_true(is_dir((string) ini_get('extension_dir')), 'extension_dir should resolve to the artifact ext directory');
    assert_true((string) ini_get('ffi.enable') !== '0', 'ffi.enable should permit CLI FFI tests');
}

function test_curl_configuration(): void
{
    require_extension_loaded('curl');
    assert_curl_userland_manifest();
    $version = curl_version();
    foreach (['version', 'ssl_version', 'libz_version', 'host', 'features', 'protocols'] as $key) {
        assert_array_has_key_string($key, $version, "curl_version should include {$key}");
    }
    $expectedCurlVersion = getenv('WINLIBS_QA_EXPECT_CURL_VERSION');
    if (is_string($expectedCurlVersion) && $expectedCurlVersion !== '') {
        assert_contains($expectedCurlVersion, (string) $version['version'], "libcurl version should be {$expectedCurlVersion}");
    } else {
        assert_true(preg_match('/^\d+\.\d+\.\d+/', (string) $version['version']) === 1, 'libcurl version should be populated');
    }
    assert_true(is_array($version['protocols']), 'curl protocols should be an array');
    foreach (['http', 'https', 'ftp', 'ftps', 'file'] as $protocol) {
        assert_true(in_array($protocol, $version['protocols'], true), "curl protocol {$protocol} should be enabled");
    }
    foreach (['CURL_VERSION_SSL', 'CURL_VERSION_LIBZ', 'CURL_VERSION_HTTP2', 'CURL_VERSION_IPV6'] as $constant) {
        assert_true(defined($constant), "{$constant} should be defined");
        assert_true(((int) $version['features'] & constant($constant)) !== 0, "{$constant} feature should be enabled");
    }
    foreach (['CURL_VERSION_BROTLI', 'CURL_VERSION_ZSTD'] as $constant) {
        if (defined($constant)) {
            assert_true(((int) $version['features'] & constant($constant)) !== 0, "{$constant} feature should be enabled");
        }
    }
    $legacyCurlRequired = in_array(php_target(), ['8.2', '8.3', '8.4', '8.5'], true);
    assert_true(defined('CURL_VERSION_NTLM'), 'CURL_VERSION_NTLM should be defined');
    $ntlmEnabled = (((int) $version['features'] & CURL_VERSION_NTLM) !== 0);
    if ($legacyCurlRequired) {
        assert_true($ntlmEnabled, 'CURL_VERSION_NTLM feature should be enabled for PHP 8.2 through 8.5');
    } else {
        suite_info('curl NTLM feature is ' . ($ntlmEnabled ? 'enabled' : 'disabled'));
    }
    foreach (['smb', 'smbs'] as $legacyProtocol) {
        $enabled = in_array($legacyProtocol, $version['protocols'], true);
        if ($legacyCurlRequired) {
            assert_true($enabled, 'curl protocol ' . $legacyProtocol . ' should be enabled for PHP 8.2 through 8.5');
        } else {
            suite_info('curl ' . strtoupper($legacyProtocol) . ' protocol is ' . ($enabled ? 'enabled' : 'disabled'));
        }
    }
    if (array_key_exists('brotli_version', $version)) {
        assert_not_same('', (string) $version['brotli_version'], 'curl brotli_version should be populated');
    }
    if (array_key_exists('zstd_version', $version)) {
        assert_not_same('', (string) $version['zstd_version'], 'curl zstd_version should be populated');
    }
    foreach (['curl_init', 'curl_exec', 'curl_multi_exec', 'curl_share_init', 'curl_escape', 'curl_file_create'] as $function) {
        assert_true(function_exists($function), "{$function} should exist");
    }

    $curlFile = curl_file_create(__FILE__, 'text/plain', 'suite.php');
    assert_same(__FILE__, $curlFile->getFilename(), 'curl_file_create should set filename');
    assert_same('text/plain', $curlFile->getMimeType(), 'curl_file_create should set MIME type');
    assert_same('suite.php', $curlFile->getPostFilename(), 'curl_file_create should set post filename');
    $curlFile->setMimeType('application/x-php');
    $curlFile->setPostFilename('renamed.php');
    assert_same('application/x-php', $curlFile->getMimeType(), 'CURLFile::setMimeType should round-trip');
    assert_same('renamed.php', $curlFile->getPostFilename(), 'CURLFile::setPostFilename should round-trip');
    $stringFile = new CURLStringFile('inline body', 'inline.txt', 'text/plain');
    assert_same('inline body', $stringFile->data, 'CURLStringFile should store inline data');
    assert_same('inline.txt', $stringFile->postname, 'CURLStringFile should store postname');
    assert_same('text/plain', $stringFile->mime, 'CURLStringFile should store MIME type');
}

function test_curl_http_surface(): void
{
    $server = new LocalHttpServer();
    $baseUrl = $server->start();
    $tmp = make_temp_dir('winlibs-curl');
    try {
        $ch = curl_init($baseUrl . '/json?hello=world');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HEADER => true,
            CURLINFO_HEADER_OUT => true,
            CURLOPT_TIMEOUT => 10,
            CURLOPT_HTTPHEADER => ['X-Winlibs-Test: curl-get'],
        ]);
        $raw = curl_exec_checked($ch);
        $info = curl_getinfo($ch);
        assert_same(200, (int) $info['http_code'], 'curl GET should return 200');
        assert_same(200, curl_getinfo($ch, CURLINFO_RESPONSE_CODE), 'curl_getinfo option should return response code');
        assert_contains('/json?hello=world', (string) curl_getinfo($ch, CURLINFO_EFFECTIVE_URL), 'curl_getinfo should report effective URL');
        assert_true($info['header_size'] > 0, 'curl should report header size');
        assert_true(is_float($info['total_time'] ?? null), 'curl_getinfo should expose timing metadata');
        assert_contains('X-Winlibs-Test: curl-get', (string) curl_getinfo($ch, CURLINFO_HEADER_OUT), 'curl should expose outgoing request headers');
        $body = substr($raw, (int) $info['header_size']);
        $payload = json_decode($body, true);
        assert_same('GET', $payload['method'] ?? null, 'curl GET method should be preserved');
        assert_same('curl-get', $payload['headers']['x-winlibs-test'] ?? null, 'curl custom request header should be sent');
        assert_true(is_int(curl_pause($ch, CURLPAUSE_CONT)), 'curl_pause(CURLPAUSE_CONT) should return a libcurl status');
        assert_true(curl_upkeep($ch), 'curl_upkeep should succeed for an initialized handle');
        $copy = curl_copy_handle($ch);
        assert_true($copy instanceof CurlHandle, 'curl_copy_handle should return a CurlHandle');
        curl_setopt_array($copy, [
            CURLOPT_HEADER => false,
            CURLOPT_URL => $baseUrl . '/headers',
            CURLOPT_RETURNTRANSFER => true,
        ]);
        $payload = json_decode(curl_exec_checked($copy), true);
        assert_same('curl-get', $payload['headers']['x-winlibs-test'] ?? null, 'curl copied handle should preserve copied headers after option changes');
        curl_close_if_needed($copy);
        curl_close_if_needed($ch);

        $ch = curl_init($baseUrl . '/json');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => 'alpha=1&beta=two',
            CURLOPT_TIMEOUT => 10,
        ]);
        $payload = json_decode(curl_exec_checked($ch), true);
        assert_same('POST', $payload['method'] ?? null, 'curl POST method should be preserved');
        assert_same('alpha=1&beta=two', $payload['body'] ?? null, 'curl POST body should be sent');
        curl_reset($ch);
        curl_setopt_array($ch, [
            CURLOPT_URL => $baseUrl . '/redirect',
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_TIMEOUT => 10,
        ]);
        $payload = json_decode(curl_exec_checked($ch), true);
        assert_contains('redirected=1', (string) ($payload['target'] ?? ''), 'curl should follow redirects');
        curl_close_if_needed($ch);

        $cookieJar = $tmp . DIRECTORY_SEPARATOR . 'cookies.txt';
        $ch = curl_init($baseUrl . '/cookie');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_COOKIEJAR => $cookieJar,
            CURLOPT_COOKIEFILE => $cookieJar,
            CURLOPT_TIMEOUT => 10,
        ]);
        curl_exec_checked($ch);
        $payload = json_decode(curl_exec_checked($ch), true);
        assert_contains('winlibs=curl', (string) ($payload['cookie'] ?? ''), 'curl cookie jar should retain cookies');
        curl_close_if_needed($ch);

        $ch = curl_init($baseUrl . '/gzip');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_ENCODING => '',
            CURLOPT_TIMEOUT => 10,
        ]);
        assert_same('compressed response body', curl_exec_checked($ch), 'curl should decode gzip responses');
        curl_close_if_needed($ch);

        $upload = $tmp . DIRECTORY_SEPARATOR . 'upload.txt';
        file_put_contents($upload, str_repeat('upload-body-', 20));
        $ch = curl_init($baseUrl . '/upload');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => ['file' => new CURLFile($upload, 'text/plain', 'upload.txt')],
            CURLOPT_TIMEOUT => 10,
        ]);
        $payload = json_decode(curl_exec_checked($ch), true);
        assert_same('POST', $payload['method'] ?? null, 'curl file upload should use POST');
        assert_greater_than(100, (int) ($payload['length'] ?? 0), 'curl multipart upload should have a meaningful body length');
        curl_close_if_needed($ch);

        $ch = curl_init($baseUrl . '/upload');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => ['inline' => new CURLStringFile('inline-upload-body', 'inline.txt', 'text/plain')],
            CURLOPT_TIMEOUT => 10,
        ]);
        $payload = json_decode(curl_exec_checked($ch), true);
        assert_same('POST', $payload['method'] ?? null, 'curl string upload should use POST');
        assert_greater_than(100, (int) ($payload['length'] ?? 0), 'curl string multipart upload should have a meaningful body length');
        curl_close_if_needed($ch);

        $sink = $tmp . DIRECTORY_SEPARATOR . 'download.json';
        $fp = fopen($sink, 'wb');
        assert_true(is_resource($fp), 'curl download sink should open');
        $ch = curl_init($baseUrl . '/json?download=1');
        curl_setopt_array($ch, [
            CURLOPT_TIMEOUT => 10,
        ]);
        assert_true(curl_setopt($ch, CURLOPT_FILE, $fp), 'curl should accept CURLOPT_FILE sink');
        assert_true(curl_exec($ch), 'curl should stream response into CURLOPT_FILE');
        fclose($fp);
        $payload = json_decode((string) file_get_contents($sink), true);
        assert_contains('download=1', (string) ($payload['target'] ?? ''), 'CURLOPT_FILE should receive response body');
        curl_close_if_needed($ch);

        $multi = curl_multi_init();
        if (defined('CURLMOPT_MAX_TOTAL_CONNECTIONS')) {
            assert_true(curl_multi_setopt($multi, CURLMOPT_MAX_TOTAL_CONNECTIONS, 4), 'curl_multi_setopt should accept max total connections');
        }
        $handles = [];
        foreach (['one', 'two'] as $id) {
            $h = curl_init($baseUrl . '/json?id=' . $id);
            curl_setopt_array($h, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10]);
            curl_multi_add_handle($multi, $h);
            $handles[] = $h;
        }
        do {
            $status = curl_multi_exec($multi, $active);
            if ($active) {
                curl_multi_select($multi, 1.0);
            }
        } while ($active && $status === CURLM_OK);
        assert_same(CURLM_OK, $status, 'curl_multi_exec should complete cleanly');
        assert_same(0, curl_multi_errno($multi), 'curl_multi_errno should report success');
        assert_not_same('', (string) curl_multi_strerror(CURLM_OK), 'curl_multi_strerror should describe CURLM_OK');
        $queuedMessages = null;
        $messages = [];
        do {
            $message = curl_multi_info_read($multi, $queuedMessages);
            if ($message !== false) {
                $messages[] = $message;
            }
        } while ($message !== false);
        assert_at_least(0, (int) $queuedMessages, 'curl_multi_info_read should set queued_messages');
        assert_at_least(1, count($messages), 'curl_multi_info_read should return completed transfer messages');
        if (function_exists('curl_multi_get_handles')) {
            assert_same(2, count(curl_multi_get_handles($multi)), 'curl_multi_get_handles should return attached handles');
        }
        foreach ($handles as $h) {
            assert_same(200, (int) curl_getinfo($h, CURLINFO_RESPONSE_CODE), 'curl_multi handle should return 200');
            assert_true(is_string(curl_multi_getcontent($h)), 'curl_multi content should be retrievable');
            curl_multi_remove_handle($multi, $h);
            curl_close_if_needed($h);
        }
        curl_multi_close($multi);

        $share = curl_share_init();
        assert_true(curl_share_setopt($share, CURLSHOPT_SHARE, CURL_LOCK_DATA_COOKIE), 'curl_share should enable cookie sharing');
        assert_same(0, curl_share_errno($share), 'curl_share_errno should report success');
        assert_not_same('', (string) curl_share_strerror(curl_share_errno($share)), 'curl_share_strerror should describe share status');
        $ch = curl_init($baseUrl . '/cookie');
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_SHARE => $share, CURLOPT_COOKIEFILE => '', CURLOPT_TIMEOUT => 10]);
        curl_exec_checked($ch);
        curl_close_if_needed($ch);
        $ch = curl_init($baseUrl . '/cookie');
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_SHARE => $share, CURLOPT_COOKIEFILE => '', CURLOPT_TIMEOUT => 10]);
        $payload = json_decode(curl_exec_checked($ch), true);
        assert_contains('winlibs=curl', (string) ($payload['cookie'] ?? ''), 'curl_share should share cookies');
        curl_close_if_needed($ch);
        $unshareCookie = curl_share_setopt($share, CURLSHOPT_UNSHARE, CURL_LOCK_DATA_COOKIE);
        assert_true(is_bool($unshareCookie), 'curl_share unshare should return a boolean');
        if (!$unshareCookie) {
            suite_info('curl_share unshare cookie returned false with errno ' . curl_share_errno($share) . ': ' . (string) curl_share_strerror(curl_share_errno($share)));
        }
        curl_share_close_if_needed($share);

        if (function_exists('curl_share_init_persistent')) {
            $persistentShare = curl_share_init_persistent([CURL_LOCK_DATA_DNS, CURL_LOCK_DATA_SSL_SESSION]);
            assert_true($persistentShare instanceof CurlSharePersistentHandle, 'curl_share_init_persistent should return a persistent share handle');
            $ch = curl_init($baseUrl . '/json?persistent=1');
            curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_SHARE => $persistentShare, CURLOPT_TIMEOUT => 10]);
            $payload = json_decode(curl_exec_checked($ch), true);
            assert_contains('persistent=1', (string) ($payload['target'] ?? ''), 'CurlSharePersistentHandle should be accepted by CURLOPT_SHARE');
            curl_close_if_needed($ch);
            expect_throwable(ValueError::class, static fn () => curl_share_init_persistent([CURL_LOCK_DATA_COOKIE]), 'Persistent curl share should reject cookie sharing');
        }
    } finally {
        rrmdir($tmp);
        $server->stop();
    }
}

function test_curl_file_error_and_encoding_helpers(): void
{
    $tmp = make_temp_dir('winlibs-curl-file');
    try {
        $file = $tmp . DIRECTORY_SEPARATOR . 'payload.txt';
        file_put_contents($file, "curl file protocol\nline two\n");
        $ch = curl_init('file:///' . str_replace('\\', '/', $file));
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10]);
        assert_same(file_get_contents($file), curl_exec_checked($ch), 'curl file protocol should read local files');
        assert_same(0, curl_errno($ch), 'curl file protocol should not set errno');
        assert_not_same('', (string) curl_strerror(CURLE_OK), 'curl_strerror should describe CURLE_OK');
        $escaped = curl_escape($ch, 'a b+c/%');
        assert_same('a%20b%2Bc%2F%25', $escaped, 'curl_escape should encode reserved characters');
        assert_same('a b+c/%', curl_unescape($ch, $escaped), 'curl_unescape should decode reserved characters');
        curl_close_if_needed($ch);

        $ch = curl_init('http://127.0.0.1:9/');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT_MS => 200,
            CURLOPT_TIMEOUT_MS => 500,
        ]);
        $result = curl_exec($ch);
        assert_false($result !== false && curl_errno($ch) === 0, 'curl connection to closed port should fail');
        assert_greater_than(0, curl_errno($ch), 'curl failed connection should set errno');
        assert_not_same('', curl_error($ch), 'curl failed connection should set error text');
        curl_close_if_needed($ch);
    } finally {
        rrmdir($tmp);
    }
}

function test_ffi_configuration_and_memory(): void
{
    require_extension_loaded('FFI');
    assert_ffi_userland_manifest();
    assert_true(class_exists(FFI::class), 'FFI class should exist');
    assert_true((string) ini_get('ffi.enable') !== '0', 'ffi.enable should be active');
    $ffi = FFI::cdef('typedef int winlibs_ffi_dummy; typedef int (*winlibs_ffi_callback)(int);');

    $intType = $ffi->type('int');
    assert_true($intType instanceof FFI\CType, 'FFI::type should return a CType');
    assert_at_least(4, $intType->getSize(), 'FFI CType int should be at least 4 bytes');
    assert_at_least(4, $intType->getAlignment(), 'FFI CType int alignment should be at least 4');
    assert_contains('int', $intType->getName(), 'FFI CType int should expose a name');

    $int = $ffi->new('int');
    $int->cdata = 42;
    assert_same(42, $int->cdata, 'FFI scalar cdata should round-trip');
    assert_at_least(4, FFI::sizeof($int), 'FFI int should be at least 4 bytes');
    assert_same($intType->getKind(), FFI::typeof($int)->getKind(), 'FFI::typeof should return scalar CType metadata');

    $array = $ffi->new('int[5]');
    for ($i = 0; $i < 5; $i++) {
        $array[$i] = $i * 3;
    }
    assert_same(12, $array[4], 'FFI arrays should support indexed writes');
    $arrayType = FFI::arrayType($intType, [3]);
    assert_same(FFI\CType::TYPE_ARRAY, $arrayType->getKind(), 'FFI::arrayType should create an array CType');
    assert_same(3, $arrayType->getArrayLength(), 'FFI array CType should expose array length');
    assert_same($intType->getKind(), $arrayType->getArrayElementType()->getKind(), 'FFI array CType should expose element type');

    $struct = $ffi->new('struct { int id; double weight; char tag[8]; }');
    $struct->id = 7;
    $struct->weight = 2.5;
    FFI::memcpy($struct->tag, "winlibs\0", 8);
    assert_same(7, $struct->id, 'FFI struct int field should round-trip');
    assert_near(2.5, $struct->weight, 0.000001, 'FFI struct double field should round-trip');
    assert_same('winlibs', FFI::string($struct->tag), 'FFI struct char buffer should round-trip');
    $structType = FFI::typeof($struct);
    assert_same(FFI\CType::TYPE_STRUCT, $structType->getKind(), 'FFI struct CType should report TYPE_STRUCT');
    assert_same(['id', 'weight', 'tag'], $structType->getStructFieldNames(), 'FFI struct CType should expose field names');
    assert_same(0, $structType->getStructFieldOffset('id'), 'FFI struct CType should expose first field offset');
    assert_same(FFI\CType::TYPE_ARRAY, $structType->getStructFieldType('tag')->getKind(), 'FFI struct CType should expose field CType');

    $buffer = $ffi->new('char[16]');
    FFI::memset($buffer, 0, FFI::sizeof($buffer));
    FFI::memcpy($buffer, 'abcdef', 6);
    assert_same('abcdef', FFI::string($buffer, 6), 'FFI memcpy/string should read copied bytes');
    $other = $ffi->new('char[16]');
    FFI::memset($other, 0, FFI::sizeof($other));
    FFI::memcpy($other, 'abcdef', 6);
    assert_same(0, FFI::memcmp($buffer, $other, 6), 'FFI memcmp should compare equal buffers');

    $ptr = FFI::addr($array[2]);
    assert_same(6, $ptr[0], 'FFI addr should expose element pointer');
    $cast = $ffi->cast('char *', $buffer);
    assert_same('abc', FFI::string($cast, 3), 'FFI cast should reinterpret pointer');
    $null = $ffi->cast('void *', 0);
    assert_true(FFI::isNull($null), 'FFI::isNull should detect null pointers');
    assert_false(FFI::isNull($cast), 'FFI::isNull should reject non-null pointers');
    $pointerType = $ffi->type('int *');
    assert_same(FFI\CType::TYPE_POINTER, $pointerType->getKind(), 'FFI pointer CType should report TYPE_POINTER');
    assert_same($intType->getKind(), $pointerType->getPointerType()->getKind(), 'FFI pointer CType should expose pointee type');
    $enumType = $ffi->type('enum { WINLIBS_ENUM_A = 1, WINLIBS_ENUM_B = 2 }');
    assert_same(FFI\CType::TYPE_ENUM, $enumType->getKind(), 'FFI enum CType should report TYPE_ENUM');
    assert_true(is_int($enumType->getEnumKind()), 'FFI enum CType should expose enum kind');
    $functionPointerType = $ffi->type('winlibs_ffi_callback');
    assert_same(FFI\CType::TYPE_POINTER, $functionPointerType->getKind(), 'FFI function pointer CType should report TYPE_POINTER');
    $functionType = $functionPointerType->getPointerType();
    assert_same(FFI\CType::TYPE_FUNC, $functionType->getKind(), 'FFI function CType should report TYPE_FUNC');
    assert_true(is_int($functionType->getFuncABI()), 'FFI function CType should expose ABI');
    assert_same($intType->getKind(), $functionType->getFuncReturnType()->getKind(), 'FFI function CType should expose return type');
    if (method_exists($functionType, 'getFuncParameterCount')) {
        assert_same(1, $functionType->getFuncParameterCount(), 'FFI function CType should expose parameter count');
        assert_same($intType->getKind(), $functionType->getFuncParameterType(0)->getKind(), 'FFI function CType should expose parameter type');
    }

    $manual = $ffi->new('char[8]', false);
    FFI::memcpy($manual, "free-ok\0", 8);
    assert_same('free-ok', FFI::string($manual), 'FFI unmanaged allocation should be writable before free');
    FFI::free($manual);

    $header = make_temp_dir('winlibs-ffi-load') . DIRECTORY_SEPARATOR . 'winlibs_ffi.h';
    try {
        file_put_contents($header, "typedef int winlibs_loaded_int;\n");
        $loaded = FFI::load($header);
        assert_true($loaded instanceof FFI, 'FFI::load should return an FFI object for a header');
        assert_true($loaded->type('winlibs_loaded_int') instanceof FFI\CType, 'FFI::load should expose typedefs from a header');
    } finally {
        rrmdir(dirname($header));
    }

    expect_throwable(FFI\Exception::class, static fn () => FFI::scope('WINLIBS_QA_MISSING_SCOPE'), 'FFI::scope should reject missing preloaded scopes');
    expect_throwable(FFI\Exception::class, static fn () => FFI::cdef('int missing(', 'kernel32.dll'), 'FFI should reject invalid C definitions');
}

function test_ffi_kernel32_calls(): void
{
    $ffi = FFI::cdef(<<<'CDEF'
typedef unsigned int DWORD;
DWORD GetCurrentProcessId(void);
DWORD GetTickCount(void);
CDEF, 'kernel32.dll');
    $pid = $ffi->GetCurrentProcessId();
    assert_same(getmypid(), (int) $pid, 'FFI kernel32 GetCurrentProcessId should match PHP pid');
    assert_at_least(1, (int) $ffi->GetTickCount(), 'FFI kernel32 GetTickCount should return uptime');
}

function glib_cdef(): string
{
    $gssize = PHP_INT_SIZE === 8 ? 'long long' : 'int';
    return <<<CDEF
typedef int gboolean;
typedef unsigned int guint;
typedef $gssize gssize;
const char *glib_check_version(guint required_major, guint required_minor, guint required_micro);
int g_ascii_strcasecmp(const char *s1, const char *s2);
gboolean g_str_has_prefix(const char *str, const char *prefix);
gboolean g_str_has_suffix(const char *str, const char *suffix);
void *g_strdup(const char *str);
char *g_strreverse(char *str);
gssize g_utf8_strlen(const char *p, gssize max);
gboolean g_utf8_validate(const char *str, gssize max_len, const char **end);
void *g_utf8_strup(const char *str, gssize len);
void *g_utf8_strdown(const char *str, gssize len);
void *g_path_get_basename(const char *file_name);
void g_free(void *mem);
CDEF;
}

function test_glib_runtime_via_ffi(): void
{
    require_extension_loaded('FFI');
    $dll = find_build_file('glib-2.dll') ?? find_build_file('glib-2.0-0.dll');
    assert_true(is_string($dll) && is_file($dll), 'glib runtime DLL should be present in the PHP artifact');
    $glib = FFI::cdef(glib_cdef(), $dll);

    $noMismatch = $glib->glib_check_version(2, 0, 0);
    assert_true($noMismatch === null, 'glib_check_version(2.0.0) should report no mismatch');
    $futureMismatch = $glib->glib_check_version(99, 0, 0);
    assert_true($futureMismatch !== null && ffi_string_value($futureMismatch) !== '', 'glib_check_version should report future-version mismatch');
    assert_same(0, $glib->g_ascii_strcasecmp('WinLibs', 'winlibs'), 'g_ascii_strcasecmp should compare ASCII case-insensitively');
    assert_same(1, (int) $glib->g_str_has_prefix('winlibs-artifact', 'winlibs'), 'g_str_has_prefix should detect prefixes');
    assert_same(1, (int) $glib->g_str_has_suffix('winlibs-artifact', 'artifact'), 'g_str_has_suffix should detect suffixes');
    assert_same(6, (int) $glib->g_utf8_strlen("héllo!", -1), 'g_utf8_strlen should count UTF-8 code points');

    $end = FFI::cdef('typedef char winlibs_ffi_char;')->new('char *');
    assert_same(1, (int) $glib->g_utf8_validate("héllo", -1, FFI::addr($end)), 'g_utf8_validate should accept valid UTF-8');
    assert_same(0, (int) $glib->g_utf8_validate("\xC3\x28", 2, FFI::addr($end)), 'g_utf8_validate should reject invalid UTF-8');

    $upper = $glib->g_utf8_strup('artifact', -1);
    assert_same('ARTIFACT', FFI::string(ffi_api()->cast('char *', $upper)), 'g_utf8_strup should uppercase ASCII UTF-8');
    $glib->g_free($upper);
    $lower = $glib->g_utf8_strdown('ARTIFACT', -1);
    assert_same('artifact', FFI::string(ffi_api()->cast('char *', $lower)), 'g_utf8_strdown should lowercase ASCII UTF-8');
    $glib->g_free($lower);
    $dup = $glib->g_strdup('desserts');
    $reversed = $glib->g_strreverse(ffi_api()->cast('char *', $dup));
    assert_same('stressed', FFI::string(ffi_api()->cast('char *', $reversed)), 'g_strdup/g_strreverse should mutate allocated strings');
    $glib->g_free($dup);
    $base = $glib->g_path_get_basename('C:/tmp/winlibs/example.txt');
    assert_same('example.txt', FFI::string(ffi_api()->cast('char *', $base)), 'g_path_get_basename should return the final component');
    $glib->g_free($base);
}

function test_enchant_configuration_and_dictionary(): void
{
    require_extension_loaded('enchant');
    assert_enchant_userland_manifest();

    assert_true((getenv('ENCHANT_MODULE_PATH') ?: '') !== '', 'ENCHANT_MODULE_PATH should be set');
    assert_true((getenv('DICPATH') ?: '') !== '', 'DICPATH should be set');
    $broker = enchant_broker_init();
    assert_true(is_object($broker), 'enchant_broker_init should return a broker object');
    $brokerError = enchant_broker_get_error($broker);
    assert_true($brokerError === false || is_string($brokerError), 'enchant_broker_get_error should return false or a string');
    $setDictPath = @enchant_broker_set_dict_path($broker, ENCHANT_MYSPELL, (string) getenv('DICPATH'));
    assert_true($setDictPath === null || is_bool($setDictPath), 'enchant_broker_set_dict_path should return null or a boolean depending on PHP branch');
    $dictPath = @enchant_broker_get_dict_path($broker, ENCHANT_MYSPELL);
    assert_true($dictPath === null || $dictPath === false || is_string($dictPath), 'enchant_broker_get_dict_path should return null, false, or a string depending on PHP branch');
    assert_true(is_bool(enchant_broker_set_ordering($broker, 'en_US', '*')), 'enchant_broker_set_ordering should return a boolean');
    $providers = enchant_broker_describe($broker);
    assert_true(is_array($providers), 'enchant_broker_describe should return an array');
    $dicts = enchant_broker_list_dicts($broker);
    assert_true(is_array($dicts), 'enchant_broker_list_dicts should return an array');
    if (enchant_broker_dict_exists($broker, 'en_US')) {
        suite_info('en_US dictionary is available through the broker');
        $dict = enchant_broker_request_dict($broker, 'en_US');
        assert_true(is_object($dict), 'enchant_broker_request_dict should return a dictionary object when en_US is present');
    } else {
        suite_info('en_US dictionary is not available; using deterministic PWL dictionary coverage');
        $pwlRoot = make_temp_dir('winlibs-enchant-pwl');
        $pwl = $pwlRoot . DIRECTORY_SEPARATOR . 'personal.pwl';
        file_put_contents($pwl, "hello\nworld\npwlword\n");
        $dict = enchant_broker_request_pwl_dict($broker, $pwl);
        assert_true(is_object($dict), 'enchant_broker_request_pwl_dict should return a dictionary object');
    }
    $description = enchant_dict_describe($dict);
    assert_true(is_array($description), 'enchant_dict_describe should return an array');
    assert_true(enchant_dict_check($dict, 'hello'), 'Known dictionary word should pass');
    assert_false(enchant_dict_check($dict, 'helllo'), 'Misspelled dictionary word should fail');
    $quickSuggestions = null;
    assert_false(enchant_dict_quick_check($dict, 'helllo', $quickSuggestions), 'enchant_dict_quick_check should fail misspellings');
    assert_true(is_array($quickSuggestions), 'enchant_dict_quick_check should populate suggestions');
    $suggestions = enchant_dict_suggest($dict, 'helllo');
    assert_true(is_array($suggestions), 'enchant_dict_suggest should return an array');
    enchant_dict_add_to_session($dict, 'sessionword');
    assert_true(enchant_dict_check($dict, 'sessionword'), 'Session-added word should pass');
    enchant_dict_add($dict, 'personalword');
    assert_true(enchant_dict_check($dict, 'personalword'), 'Added word should pass');
    assert_true(enchant_dict_is_added($dict, 'personalword'), 'enchant_dict_is_added should see added words');
    assert_true(@enchant_dict_is_in_session($dict, 'personalword'), 'enchant_dict_is_in_session alias should see added words');
    @enchant_dict_add_to_personal($dict, 'aliaspersonalword');
    assert_true(enchant_dict_check($dict, 'aliaspersonalword'), 'Deprecated personal-word alias should add words');
    if (function_exists('enchant_dict_remove')) {
        enchant_dict_add($dict, 'removeword');
        assert_true(enchant_dict_check($dict, 'removeword'), 'Word scheduled for removal should pass after add');
        enchant_dict_remove($dict, 'removeword');
        assert_false(enchant_dict_check($dict, 'removeword'), 'enchant_dict_remove should remove added words');
    }
    if (function_exists('enchant_dict_remove_from_session')) {
        enchant_dict_add_to_session($dict, 'sessionremoveword');
        assert_true(enchant_dict_check($dict, 'sessionremoveword'), 'Session word scheduled for removal should pass after add');
        enchant_dict_remove_from_session($dict, 'sessionremoveword');
        assert_false(enchant_dict_check($dict, 'sessionremoveword'), 'enchant_dict_remove_from_session should remove session words');
    }
    enchant_dict_store_replacement($dict, 'helllo', 'hello');
    $dictError = enchant_dict_get_error($dict);
    assert_true($dictError === false || is_string($dictError), 'enchant_dict_get_error should return false or a string');
    assert_true(@enchant_broker_free_dict($dict), 'Deprecated enchant_broker_free_dict should return true');
    assert_true(@enchant_broker_free($broker), 'Deprecated enchant_broker_free should return true');

    if (isset($pwlRoot)) {
        rrmdir($pwlRoot);
    }
}

function test_gd_jpeg_configuration(): void
{
    require_extension_loaded('gd');
    assert_gd_jpeg_userland_manifest();
    $info = gd_info();
    assert_true(($info['JPEG Support'] ?? false) === true, 'GD JPEG Support should be enabled');
    assert_true((imagetypes() & IMG_JPG) === IMG_JPG, 'IMG_JPG should be present in imagetypes');
    assert_same(IMG_JPG, IMG_JPEG, 'IMG_JPEG should alias IMG_JPG');
    assert_same('image/jpeg', image_type_to_mime_type(IMAGETYPE_JPEG), 'JPEG MIME type helper should report image/jpeg');
    assert_same('.jpeg', image_type_to_extension(IMAGETYPE_JPEG), 'JPEG extension helper should include the leading dot by default');
    assert_same('jpeg', image_type_to_extension(IMAGETYPE_JPEG, false), 'JPEG extension helper should omit the dot when requested');
    assert_true(function_exists('imagejpeg'), 'imagejpeg should exist');
    assert_true(function_exists('imagecreatefromjpeg'), 'imagecreatefromjpeg should exist');
}

function test_gd_jpeg_encoding_decoding_and_markers(): void
{
    $tmp = make_temp_dir('winlibs-jpeg');
    try {
        $image = create_reference_image();
        $low = $tmp . DIRECTORY_SEPARATOR . 'low.jpg';
        $high = $tmp . DIRECTORY_SEPARATOR . 'high.jpg';
        $lowest = $tmp . DIRECTORY_SEPARATOR . 'quality-0.jpg';
        $highest = $tmp . DIRECTORY_SEPARATOR . 'quality-100.jpg';
        $progressive = $tmp . DIRECTORY_SEPARATOR . 'progressive.jpg';
        ob_start();
        assert_true(imagejpeg($image, null, -1), 'imagejpeg should write to output buffer when file is null');
        $defaultBytes = (string) ob_get_clean();
        assert_true(str_starts_with($defaultBytes, "\xFF\xD8"), 'Buffered JPEG should start with SOI marker');
        assert_true(imagejpeg($image, $low, 35), 'imagejpeg low quality should succeed');
        assert_true(imagejpeg($image, $high, 95), 'imagejpeg high quality should succeed');
        assert_true(imagejpeg($image, $lowest, 0), 'imagejpeg quality 0 should succeed');
        assert_true(imagejpeg($image, $highest, 100), 'imagejpeg quality 100 should succeed');
        imageinterlace($image, true);
        assert_true(imagejpeg($image, $progressive, 80), 'imagejpeg progressive should succeed');
        assert_greater_than(100, filesize($low), 'Low quality JPEG should not be empty');
        assert_greater_than(filesize($low), filesize($high), 'High quality JPEG should generally be larger than low quality');
        assert_greater_than(filesize($lowest), filesize($highest), 'Quality 100 JPEG should generally be larger than quality 0');

        $size = getimagesize($high);
        assert_same(96, $size[0], 'JPEG width should survive');
        assert_same(64, $size[1], 'JPEG height should survive');
        assert_same(IMAGETYPE_JPEG, $size[2], 'getimagesize should report JPEG');
        $fromStringSize = getimagesizefromstring((string) file_get_contents($high));
        assert_same($size[0], $fromStringSize[0], 'getimagesizefromstring should preserve width');
        assert_same($size[1], $fromStringSize[1], 'getimagesizefromstring should preserve height');
        if (function_exists('exif_imagetype')) {
            assert_same(IMAGETYPE_JPEG, exif_imagetype($high), 'exif_imagetype should report JPEG');
        }
        $decoded = imagecreatefromjpeg($high);
        assert_true($decoded instanceof GdImage, 'imagecreatefromjpeg should return GdImage');
        assert_same(96, imagesx($decoded), 'Decoded JPEG width should match');
        assert_same(64, imagesy($decoded), 'Decoded JPEG height should match');
        assert_true(imageistruecolor($decoded), 'Decoded JPEG should be truecolor');
        $decodedFromString = imagecreatefromstring((string) file_get_contents($high));
        assert_true($decodedFromString instanceof GdImage, 'imagecreatefromstring should decode JPEG bytes');
        assert_same(96, imagesx($decodedFromString), 'String-decoded JPEG width should match');
        $resampled = imagecreatetruecolor(48, 32);
        assert_true(imagecopyresampled($resampled, $decoded, 0, 0, 0, 0, 48, 32, 96, 64), 'Decoded JPEG should be usable for resampling');
        imagefilter($decoded, IMG_FILTER_GRAYSCALE);
        $gray = $tmp . DIRECTORY_SEPARATOR . 'gray.jpg';
        assert_true(imagejpeg($decoded, $gray, 75), 'Filtered JPEG should encode');
        assert_true(in_array(0xC2, jpeg_markers((string) file_get_contents($progressive)), true), 'Progressive JPEG should contain SOF2 marker');

        [$invalid, $warning] = capture_warning(static fn () => imagecreatefromjpeg(__FILE__));
        assert_false($invalid instanceof GdImage, 'Invalid JPEG decode should fail');
        assert_true(is_string($warning) && $warning !== '', 'Invalid JPEG decode should emit a warning');
    } finally {
        rrmdir($tmp);
    }
}

function test_intl_configuration_and_manifest(): void
{
    require_extension_loaded('intl');
    assert_intl_userland_manifest();
    assert_constants_defined([
        'INTL_ICU_VERSION',
        'INTL_ICU_DATA_VERSION',
        'INTL_MAX_LOCALE_LEN',
        'INTL_IDNA_VARIANT_UTS46',
        'IDNA_DEFAULT',
        'IDNA_CHECK_BIDI',
        'IDNA_CHECK_CONTEXTJ',
    ], 'intl');
    $minimumIcuVersion = minimum_icu_version_for_target();
    assert_true(version_compare(INTL_ICU_VERSION, $minimumIcuVersion, '>='), "INTL_ICU_VERSION should be at least {$minimumIcuVersion} for " . php_target());
    assert_true(version_compare(INTL_ICU_DATA_VERSION, $minimumIcuVersion, '>='), "INTL_ICU_DATA_VERSION should be at least {$minimumIcuVersion} for " . php_target());
    assert_same(0, intl_get_error_code(), 'intl_get_error_code should start clean');
    assert_false(intl_is_failure(intl_get_error_code()), 'intl_is_failure should reject U_ZERO_ERROR');
    assert_not_same('', intl_error_name(intl_get_error_code()), 'intl_error_name should describe U_ZERO_ERROR');
    assert_true(is_string(intl_get_error_message()), 'intl_get_error_message should return a string');

    $intlRi = getenv('WINLIBS_QA_INTL_RI');
    if (is_string($intlRi) && $intlRi !== '' && is_file($intlRi)) {
        $ri = (string) file_get_contents($intlRi);
        assert_contains('Internationalization support => enabled', $ri, 'php --ri intl should report intl support');
        assert_contains('ICU version => ' . INTL_ICU_VERSION, $ri, 'php --ri intl should match INTL_ICU_VERSION');
        assert_contains('ICU Data version => ' . INTL_ICU_DATA_VERSION, $ri, 'php --ri intl should match INTL_ICU_DATA_VERSION');
        assert_true(preg_match('/ICU Unicode version => \d+\.\d+/', $ri) === 1, 'php --ri intl should report ICU Unicode version');
    }
}

function test_intl_locale_grapheme_normalizer_char_idn(): void
{
    $oldLocale = Locale::getDefault();
    Locale::setDefault('en_US');
    try {
        assert_same('en_US', Locale::getDefault(), 'Locale default should round-trip');
        $composed = Locale::composeLocale([
            Locale::LANG_TAG => 'zh',
            Locale::SCRIPT_TAG => 'Hant',
            Locale::REGION_TAG => 'TW',
        ]);
        assert_same('zh_Hant_TW', $composed, 'Locale::composeLocale should compose language/script/region');
        $parsed = Locale::parseLocale('sl-Latn-IT-nedis');
        assert_same('sl', $parsed['language'] ?? null, 'Locale::parseLocale should parse language');
        assert_same('Latn', $parsed['script'] ?? null, 'Locale::parseLocale should parse script');
        assert_same('IT', $parsed['region'] ?? null, 'Locale::parseLocale should parse region');
        assert_same('en', Locale::getPrimaryLanguage('en_US_POSIX'), 'Locale primary language should be en');
        assert_same('Latn', Locale::getScript('sr_Latn_RS'), 'Locale script should be Latn');
        assert_same('US', Locale::getRegion('en_US'), 'Locale region should be US');
        assert_same(['currency' => 'USD'], Locale::getKeywords('en_US@currency=USD'), 'Locale keywords should parse currency');
        assert_contains('English', Locale::getDisplayLanguage('en_US', 'en_US'), 'Locale display language should be English');
        assert_contains('United States', Locale::getDisplayRegion('en_US', 'en_US'), 'Locale display region should be United States');
        assert_contains('Latin', Locale::getDisplayScript('sr_Latn_RS', 'en_US'), 'Locale display script should include Latin');
        assert_true(is_string(Locale::getDisplayVariant('sl_IT_NEDIS', 'en_US')), 'Locale display variant should return a string');
        assert_contains('English', Locale::getDisplayName('en_US', 'en_US'), 'Locale display name should include English');
        assert_same(['POSIX'], Locale::getAllVariants('en_US_POSIX'), 'Locale variants should include POSIX');
        assert_true(Locale::filterMatches('de-DE', 'de'), 'Locale filter should match a broader locale range');
        assert_same('en_US', Locale::lookup(['en_US', 'fr_FR'], 'en-US-x-private'), 'Locale lookup should pick en_US');
        assert_same('en_US', Locale::canonicalize('EN-us'), 'Locale canonicalize should normalize case/separators');
        assert_same('fr_CA', Locale::acceptFromHttp('fr-CA,fr;q=0.8,en-US;q=0.5'), 'Locale acceptFromHttp should pick the best language range');
        if (method_exists(Locale::class, 'isRightToLeft')) {
            assert_false(Locale::isRightToLeft('en-US'), 'Locale::isRightToLeft should reject English');
            assert_true(Locale::isRightToLeft('ar'), 'Locale::isRightToLeft should detect Arabic');
        }
        if (method_exists(Locale::class, 'addLikelySubtags')) {
            $maximized = Locale::addLikelySubtags('zh');
            assert_true(is_string($maximized) && str_contains($maximized, 'Hans'), 'Locale::addLikelySubtags should maximize zh');
            assert_true(is_string(Locale::minimizeSubtags($maximized)), 'Locale::minimizeSubtags should return a string for maximized locale');
        }

        $combining = "Cafe\u{0301}";
        $normalized = Normalizer::normalize($combining, Normalizer::FORM_C);
        assert_same("Caf\u{00E9}", $normalized, 'Normalizer should compose e + acute');
        assert_false(Normalizer::isNormalized($combining, Normalizer::FORM_C), 'Normalizer should detect decomposed text');
        assert_true(Normalizer::isNormalized($normalized, Normalizer::FORM_C), 'Normalizer should detect NFC text');
        assert_true(is_string(Normalizer::getRawDecomposition("\u{00C5}")), 'Normalizer raw decomposition should return a string for Angstrom');

        assert_same(4, grapheme_strlen($combining), 'grapheme_strlen should count user-visible characters');
        assert_same("e\u{0301}", grapheme_substr($combining, 3, 1), 'grapheme_substr should keep combining mark with base');
        assert_same(3, grapheme_strpos($combining, "e\u{0301}"), 'grapheme_strpos should locate a grapheme cluster');
        assert_same(3, grapheme_stripos($combining, "E\u{0301}"), 'grapheme_stripos should locate case-insensitive grapheme cluster');
        assert_same(7, grapheme_strrpos($combining . $combining, "e\u{0301}"), 'grapheme_strrpos should return the last grapheme offset');
        assert_same(7, grapheme_strripos($combining . $combining, "E\u{0301}"), 'grapheme_strripos should return the last case-insensitive grapheme offset');
        assert_same("e\u{0301}", grapheme_strstr($combining, "e\u{0301}"), 'grapheme_strstr should return matching tail');
        assert_same("e\u{0301}", grapheme_stristr($combining, "E\u{0301}"), 'grapheme_stristr should return matching tail');
        if (function_exists('grapheme_str_split')) {
            assert_same(['C', 'a', 'f', "e\u{0301}"], grapheme_str_split($combining), 'grapheme_str_split should split clusters');
        }
        $next = 0;
        assert_same('Caf', grapheme_extract($combining, 3, GRAPHEME_EXTR_COUNT, 0, $next), 'grapheme_extract should extract by cluster count');
        assert_same(3, $next, 'grapheme_extract should update next offset');
        if (function_exists('grapheme_levenshtein')) {
            assert_same(0, grapheme_levenshtein("e\u{0301}", "\u{00E9}"), 'grapheme_levenshtein should compare canonically equivalent text');
        }
        if (function_exists('grapheme_strrev')) {
            assert_same("e\u{0301}faC", grapheme_strrev($combining), 'grapheme_strrev should reverse grapheme clusters');
        }

        assert_same('LATIN CAPITAL LETTER A', IntlChar::charName('A'), 'IntlChar::charName should name A');
        assert_same(0x41, IntlChar::charFromName('LATIN CAPITAL LETTER A'), 'IntlChar::charFromName should find A');
        assert_same('A', IntlChar::chr(0x41), 'IntlChar::chr should create A');
        assert_same(0x41, IntlChar::ord('A'), 'IntlChar::ord should return code point');
        assert_same(15, IntlChar::digit('F', 16), 'IntlChar::digit should parse hex F');
        assert_same(0x66, IntlChar::forDigit(15, 16), 'IntlChar::forDigit should return code point for hex f');
        assert_same('a', IntlChar::tolower('A'), 'IntlChar::tolower should lowercase');
        assert_same('A', IntlChar::toupper('a'), 'IntlChar::toupper should uppercase');
        assert_same('A', IntlChar::totitle('a'), 'IntlChar::totitle should titlecase');
        assert_same('a', IntlChar::foldCase('A'), 'IntlChar::foldCase should fold case');
        assert_true(IntlChar::hasBinaryProperty('A', IntlChar::PROPERTY_ALPHABETIC), 'IntlChar binary alphabetic property should be true for A');
        assert_same(IntlChar::CHAR_DIRECTION_LEFT_TO_RIGHT, IntlChar::charDirection('A'), 'IntlChar direction should be LTR for A');
        assert_same(')', IntlChar::charMirror('('), 'IntlChar mirror should mirror parentheses');
        assert_same(IntlChar::CHAR_CATEGORY_UPPERCASE_LETTER, IntlChar::charType('A'), 'IntlChar type should be uppercase letter');
        assert_true(is_array(IntlChar::charAge('A')), 'IntlChar age should return an array');
        assert_same(7, IntlChar::charDigitValue('7'), 'IntlChar digit value should parse 7');
        assert_same(')', IntlChar::getBidiPairedBracket('('), 'IntlChar paired bracket should close parentheses');
        assert_same(IntlChar::BLOCK_CODE_BASIC_LATIN, IntlChar::getBlockCode('A'), 'IntlChar block should be Basic Latin');
        assert_greater_than(0, IntlChar::getCombiningClass("\u{0301}"), 'IntlChar combining class should be positive for acute mark');
        assert_true(is_string(IntlChar::getFC_NFKC_Closure('A')), 'IntlChar FC_NFKC closure should return a string');
        assert_same(0, IntlChar::getIntPropertyMinValue(IntlChar::PROPERTY_SCRIPT), 'IntlChar script min property should be zero');
        assert_greater_than(0, IntlChar::getIntPropertyMaxValue(IntlChar::PROPERTY_SCRIPT), 'IntlChar script max property should be positive');
        $latinScript = IntlChar::getPropertyValueEnum(IntlChar::PROPERTY_SCRIPT, 'Latin');
        assert_same($latinScript, IntlChar::getIntPropertyValue('A', IntlChar::PROPERTY_SCRIPT), 'IntlChar script property should be Latin for A');
        assert_same(IntlChar::PROPERTY_SCRIPT, IntlChar::getPropertyEnum('script'), 'IntlChar property enum should find script');
        assert_same('Script', IntlChar::getPropertyName(IntlChar::PROPERTY_SCRIPT, IntlChar::LONG_PROPERTY_NAME), 'IntlChar property name should be Script');
        assert_same('Latin', IntlChar::getPropertyValueName(IntlChar::PROPERTY_SCRIPT, $latinScript, IntlChar::LONG_PROPERTY_NAME), 'IntlChar property value name should be Latin');
        assert_true(is_array(IntlChar::getUnicodeVersion()), 'IntlChar Unicode version should return array');
        assert_same(12.0, IntlChar::getNumericValue("\u{216B}"), 'IntlChar numeric value should parse Roman numeral twelve');
        foreach (['isalnum', 'isalpha', 'isbase', 'isdefined', 'isdigit', 'isgraph', 'isIDPart', 'isIDStart', 'isJavaIDPart', 'isJavaIDStart', 'islower', 'isprint', 'isUAlphabetic', 'isULowercase', 'isupper', 'isUUppercase', 'isxdigit'] as $method) {
            assert_true(is_bool(IntlChar::$method($method === 'isdigit' ? '7' : 'A')), "IntlChar::{$method} should return bool");
        }
        foreach (['isblank', 'iscntrl', 'isIDIgnorable', 'isISOControl', 'isJavaSpaceChar', 'isMirrored', 'ispunct', 'isspace', 'istitle', 'isUWhiteSpace', 'isWhitespace'] as $method) {
            assert_true(is_bool(IntlChar::$method($method === 'isMirrored' ? '(' : ' ')), "IntlChar::{$method} should return bool");
        }
        $names = [];
        IntlChar::enumCharNames(0x41, 0x43, static function (int $codepoint, int $type, string $name) use (&$names): void {
            $names[$codepoint] = $name;
        });
        assert_same('LATIN CAPITAL LETTER A', $names[0x41] ?? null, 'IntlChar::enumCharNames should enumerate A');
        $types = [];
        IntlChar::enumCharTypes(static function (int $start, int $end, int $type) use (&$types): bool {
            $types[] = [$start, $end, $type];
            return count($types) < 3;
        });
        assert_at_least(1, count($types), 'IntlChar::enumCharTypes should enumerate ranges');

        $ascii = idn_to_ascii('münich.example', IDNA_DEFAULT, INTL_IDNA_VARIANT_UTS46);
        assert_same('xn--mnich-kva.example', $ascii, 'idn_to_ascii should convert U-label to A-label');
        assert_same('münich.example', idn_to_utf8($ascii, IDNA_DEFAULT, INTL_IDNA_VARIANT_UTS46), 'idn_to_utf8 should convert A-label to U-label');
    } finally {
        Locale::setDefault($oldLocale);
    }
}

function test_intl_collator_number_message_date(): void
{
    $collator = Collator::create('en_US');
    assert_true($collator instanceof Collator, 'Collator::create should return Collator');
    assert_true($collator->compare('apple', 'banana') < 0, 'Collator should compare strings');
    assert_true(collator_compare($collator, 'apple', 'banana') < 0, 'collator_compare should compare strings');
    assert_true($collator->setStrength(Collator::PRIMARY), 'Collator setStrength should succeed');
    assert_same(Collator::PRIMARY, $collator->getStrength(), 'Collator getStrength should round-trip');
    assert_true($collator->setAttribute(Collator::NUMERIC_COLLATION, Collator::ON), 'Collator setAttribute should enable numeric collation');
    assert_same(Collator::ON, $collator->getAttribute(Collator::NUMERIC_COLLATION), 'Collator getAttribute should see numeric collation');
    $items = ['item10', 'item2', 'item1'];
    assert_true($collator->sort($items), 'Collator sort should succeed');
    assert_same(['item1', 'item2', 'item10'], $items, 'Collator numeric sort should order numeric suffixes');
    $assoc = ['b' => 'éclair', 'a' => 'apple'];
    assert_true($collator->asort($assoc), 'Collator asort should succeed');
    assert_same(['a' => 'apple', 'b' => 'éclair'], $assoc, 'Collator asort should preserve keys');
    $sortKeyA = $collator->getSortKey('a');
    $sortKeyB = collator_get_sort_key($collator, 'b');
    assert_true(is_string($sortKeyA) && is_string($sortKeyB) && $sortKeyA < $sortKeyB, 'Collator sort keys should be ordered');
    $words = ['éclair', 'apple', 'Banana'];
    assert_true($collator->sortWithSortKeys($words), 'Collator sortWithSortKeys should succeed');
    assert_same(0, $collator->getErrorCode(), 'Collator error code should be zero');
    assert_true(is_string($collator->getErrorMessage()), 'Collator error message should return string');
    assert_true(is_string($collator->getLocale(Locale::VALID_LOCALE)), 'Collator locale should return string');

    $decimal = NumberFormatter::create('en_US', NumberFormatter::DECIMAL);
    assert_true($decimal instanceof NumberFormatter, 'NumberFormatter::create should return formatter');
    assert_true($decimal->setAttribute(NumberFormatter::GROUPING_USED, 0), 'NumberFormatter setAttribute should disable grouping');
    assert_same(0, $decimal->getAttribute(NumberFormatter::GROUPING_USED), 'NumberFormatter getAttribute should see grouping flag');
    assert_same('1234.5', $decimal->format(1234.5), 'NumberFormatter decimal format should be deterministic without grouping');
    assert_same(1234.5, $decimal->parse('1234.5', NumberFormatter::TYPE_DOUBLE), 'NumberFormatter parse should parse double');
    assert_true($decimal->setSymbol(NumberFormatter::DECIMAL_SEPARATOR_SYMBOL, '*'), 'NumberFormatter setSymbol should change decimal separator');
    assert_same('*', $decimal->getSymbol(NumberFormatter::DECIMAL_SEPARATOR_SYMBOL), 'NumberFormatter getSymbol should see separator');
    assert_true($decimal->setTextAttribute(NumberFormatter::POSITIVE_PREFIX, '+'), 'NumberFormatter setTextAttribute should set prefix');
    assert_same('+', $decimal->getTextAttribute(NumberFormatter::POSITIVE_PREFIX), 'NumberFormatter getTextAttribute should see prefix');
    assert_true($decimal->setPattern('0000.00'), 'NumberFormatter setPattern should succeed');
    assert_contains('0000.00', $decimal->getPattern(), 'NumberFormatter getPattern should include numeric pattern');
    assert_true(is_string($decimal->getLocale(Locale::VALID_LOCALE)), 'NumberFormatter locale should return string');
    assert_same(0, $decimal->getErrorCode(), 'NumberFormatter error code should be zero');
    assert_true(is_string($decimal->getErrorMessage()), 'NumberFormatter error message should return string');
    $currency = numfmt_create('en_US', NumberFormatter::CURRENCY);
    assert_true($currency instanceof NumberFormatter, 'numfmt_create should return formatter');
    assert_contains('12.30', numfmt_format_currency($currency, 12.3, 'USD'), 'numfmt_format_currency should format USD amount');
    $currencyCode = null;
    $parsedCurrency = numfmt_parse_currency($currency, '$12.30', $currencyCode);
    assert_same('USD', $currencyCode, 'numfmt_parse_currency should detect USD');
    assert_near(12.3, (float) $parsedCurrency, 0.001, 'numfmt_parse_currency should parse amount');
    $spellout = new NumberFormatter('en_US', NumberFormatter::SPELLOUT);
    assert_contains('forty-two', $spellout->format(42), 'NumberFormatter spellout should spell 42');

    $message = new MessageFormatter('en_US', '{0, plural, one{# file} other{# files}}');
    assert_same('2 files', $message->format([2]), 'MessageFormatter should format plural messages');
    assert_same('1 file', msgfmt_format($message, [1]), 'msgfmt_format should format plural message');
    assert_same('3 files', MessageFormatter::formatMessage('en_US', '{0, plural, one{# file} other{# files}}', [3]), 'MessageFormatter::formatMessage should format plural message');
    assert_same('4 files', msgfmt_format_message('en_US', '{0, plural, one{# file} other{# files}}', [4]), 'msgfmt_format_message should format plural message');
    $parseMessage = MessageFormatter::create('en_US', '{0,number,integer} files');
    assert_same([12], $parseMessage->parse('12 files'), 'MessageFormatter parse should parse integer argument');
    assert_same([13], msgfmt_parse($parseMessage, '13 files'), 'msgfmt_parse should parse integer argument');
    assert_same([14], MessageFormatter::parseMessage('en_US', '{0,number,integer} files', '14 files'), 'MessageFormatter::parseMessage should parse integer argument');
    assert_true($message->setPattern('{0,select,male{he} female{she} other{they}}'), 'MessageFormatter setPattern should succeed');
    assert_contains('select', $message->getPattern(), 'MessageFormatter getPattern should reflect select pattern');
    assert_same('she', $message->format(['female']), 'MessageFormatter select pattern should format');
    assert_true(is_string($message->getLocale()), 'MessageFormatter locale should return string');
    assert_same(0, $message->getErrorCode(), 'MessageFormatter error code should be zero');
    assert_true(is_string($message->getErrorMessage()), 'MessageFormatter error message should return string');

    $date = IntlDateFormatter::create('en_US', IntlDateFormatter::NONE, IntlDateFormatter::NONE, 'UTC', IntlDateFormatter::GREGORIAN, 'yyyy-MM-dd HH:mm');
    assert_true($date instanceof IntlDateFormatter, 'IntlDateFormatter::create should return formatter');
    assert_same('1970-01-01 00:00', $date->format(0), 'IntlDateFormatter should format epoch in UTC');
    assert_same('1970-01-01 00:00', datefmt_format($date, 0), 'datefmt_format should format epoch in UTC');
    $parsePos = 0;
    assert_same(0, $date->parse('1970-01-01 00:00', $parsePos), 'IntlDateFormatter parse should parse epoch');
    assert_greater_than(0, $parsePos, 'IntlDateFormatter parse should update parse position');
    $localtime = $date->localtime('1970-01-01 00:00');
    assert_same(70, $localtime['tm_year'] ?? null, 'IntlDateFormatter localtime should parse year offset');
    if (method_exists($date, 'parseToCalendar')) {
        assert_true($date->parseToCalendar('1970-01-01 00:00') !== false, 'IntlDateFormatter parseToCalendar should parse date text');
    }
    assert_same('1970-01-01', IntlDateFormatter::formatObject(new DateTimeImmutable('@0'), 'yyyy-MM-dd', 'en_US'), 'IntlDateFormatter::formatObject should format DateTime');
    assert_same('1970-01-01', datefmt_format_object(new DateTimeImmutable('@0'), 'yyyy-MM-dd', 'en_US'), 'datefmt_format_object should format DateTime');
    assert_same(IntlDateFormatter::NONE, $date->getDateType(), 'IntlDateFormatter date type should be NONE');
    assert_same(IntlDateFormatter::NONE, $date->getTimeType(), 'IntlDateFormatter time type should be NONE');
    assert_same(IntlDateFormatter::GREGORIAN, $date->getCalendar(), 'IntlDateFormatter calendar should be Gregorian');
    assert_true($date->getCalendarObject() instanceof IntlCalendar, 'IntlDateFormatter getCalendarObject should return IntlCalendar');
    assert_same('UTC', $date->getTimeZoneId(), 'IntlDateFormatter timezone ID should be UTC');
    assert_true($date->getTimeZone() instanceof IntlTimeZone, 'IntlDateFormatter getTimeZone should return IntlTimeZone');
    $date->setTimeZone('America/New_York');
    assert_same('America/New_York', $date->getTimeZone()->getID(), 'IntlDateFormatter setTimeZone should accept IDs');
    $date->setCalendar(IntlDateFormatter::GREGORIAN);
    $date->setPattern('yyyy/MM/dd');
    assert_same('yyyy/MM/dd', $date->getPattern(), 'IntlDateFormatter getPattern should round-trip');
    $date->setLenient(false);
    assert_false($date->isLenient(), 'IntlDateFormatter lenient flag should round-trip');
    assert_true(is_string($date->getLocale(Locale::VALID_LOCALE)), 'IntlDateFormatter locale should return string');
    assert_same(0, $date->getErrorCode(), 'IntlDateFormatter error code should be zero');
    assert_true(is_string($date->getErrorMessage()), 'IntlDateFormatter error message should return string');

    $generator = IntlDatePatternGenerator::create('en_US');
    assert_true($generator instanceof IntlDatePatternGenerator, 'IntlDatePatternGenerator::create should return generator');
    assert_same('MMM d, y', $generator->getBestPattern('yMMMd'), 'IntlDatePatternGenerator should return best US pattern');
}

function test_intl_calendar_timezone(): void
{
    $losAngeles = IntlTimeZone::createTimeZone('America/Los_Angeles');
    assert_true($losAngeles instanceof IntlTimeZone, 'IntlTimeZone::createTimeZone should create America/Los_Angeles');
    assert_same('America/Los_Angeles', $losAngeles->getID(), 'IntlTimeZone getID should round-trip IANA ID');
    assert_same(-28800000, $losAngeles->getRawOffset(), 'America/Los_Angeles raw offset should be UTC-8');
    assert_same(3600000, $losAngeles->getDSTSavings(), 'America/Los_Angeles DST savings should be one hour');
    assert_true($losAngeles->useDaylightTime(), 'America/Los_Angeles should use daylight saving time');
    assert_contains('Pacific', $losAngeles->getDisplayName(false, IntlTimeZone::DISPLAY_LONG, 'en_US'), 'Timezone display name should be Pacific');
    assert_same('US', IntlTimeZone::getRegion('America/Los_Angeles'), 'IntlTimeZone::getRegion should return US');
    assert_same('Pacific Standard Time', IntlTimeZone::getWindowsID('America/Los_Angeles'), 'IntlTimeZone::getWindowsID should map to Windows ID');
    assert_same('America/Los_Angeles', IntlTimeZone::getIDForWindowsID('Pacific Standard Time', 'US'), 'IntlTimeZone::getIDForWindowsID should map back to IANA ID');
    if (method_exists(IntlTimeZone::class, 'getIanaID')) {
        assert_true(IntlTimeZone::getIanaID('Pacific Standard Time') === false || is_string(IntlTimeZone::getIanaID('Pacific Standard Time')), 'IntlTimeZone::getIanaID should return string or false for Windows IDs');
    }
    $isSystemId = null;
    assert_same('America/Los_Angeles', IntlTimeZone::getCanonicalID('US/Pacific', $isSystemId), 'IntlTimeZone::getCanonicalID should canonicalize aliases');
    assert_true(is_bool($isSystemId), 'IntlTimeZone::getCanonicalID should set system-ID flag');
    $rawOffset = null;
    $dstOffset = null;
    assert_true($losAngeles->getOffset(0.0, false, $rawOffset, $dstOffset), 'IntlTimeZone getOffset should succeed');
    assert_same(-28800000, $rawOffset, 'IntlTimeZone getOffset should populate raw offset');
    assert_same(0, $dstOffset, 'IntlTimeZone getOffset should populate DST offset for epoch');
    assert_same(0, IntlTimeZone::getGMT()->getRawOffset(), 'GMT raw offset should be zero');
    assert_same(0, IntlTimeZone::createTimeZone('UTC')->getRawOffset(), 'UTC raw offset should be zero');
    assert_same('Etc/Unknown', IntlTimeZone::getUnknown()->getID(), 'IntlTimeZone::getUnknown should expose unknown timezone');
    assert_true(IntlTimeZone::fromDateTimeZone(new DateTimeZone('UTC')) instanceof IntlTimeZone, 'IntlTimeZone::fromDateTimeZone should convert DateTimeZone');
    assert_true($losAngeles->toDateTimeZone() instanceof DateTimeZone, 'IntlTimeZone::toDateTimeZone should convert to DateTimeZone');
    assert_true(is_string(IntlTimeZone::getTZDataVersion()), 'IntlTimeZone::getTZDataVersion should return a string');
    assert_same(0, $losAngeles->getErrorCode(), 'IntlTimeZone error code should be zero');
    assert_true(is_string($losAngeles->getErrorMessage()), 'IntlTimeZone error message should return string');
    assert_true(IntlTimeZone::countEquivalentIDs('UTC') >= 1, 'IntlTimeZone equivalent IDs should be countable');
    assert_true(is_string(IntlTimeZone::getEquivalentID('UTC', 0)), 'IntlTimeZone equivalent ID should return a string');
    assert_true(intltz_create_time_zone('UTC') instanceof IntlTimeZone, 'intltz_create_time_zone should return IntlTimeZone');
    assert_same('UTC', intltz_get_id(intltz_create_time_zone('UTC')), 'intltz_get_id should return UTC');
    assert_same(0, intltz_get_raw_offset(intltz_create_time_zone('UTC')), 'intltz_get_raw_offset should return zero for UTC');
    assert_true(intltz_to_date_time_zone(intltz_create_time_zone('UTC')) instanceof DateTimeZone, 'intltz_to_date_time_zone should convert to DateTimeZone');

    $foundLosAngeles = false;
    foreach (IntlTimeZone::createEnumeration('US') as $timeZoneId) {
        $foundLosAngeles = $foundLosAngeles || $timeZoneId === 'America/Los_Angeles';
    }
    assert_true($foundLosAngeles, 'IntlTimeZone::createEnumeration should include America/Los_Angeles for US');
    $foundCanonicalLosAngeles = false;
    foreach (IntlTimeZone::createTimeZoneIDEnumeration(IntlTimeZone::TYPE_CANONICAL_LOCATION, 'US', null) as $timeZoneId) {
        $foundCanonicalLosAngeles = $foundCanonicalLosAngeles || $timeZoneId === 'America/Los_Angeles';
    }
    assert_true($foundCanonicalLosAngeles, 'IntlTimeZone::createTimeZoneIDEnumeration should include canonical America/Los_Angeles');
    assert_true(intltz_create_enumeration('US') instanceof IntlIterator, 'intltz_create_enumeration should return IntlIterator');
    assert_true(intltz_create_time_zone_id_enumeration(IntlTimeZone::TYPE_CANONICAL_LOCATION, 'US', null) instanceof IntlIterator, 'intltz_create_time_zone_id_enumeration should return IntlIterator');

    $calendar = IntlCalendar::createInstance(IntlTimeZone::createTimeZone('UTC'), 'en_US');
    assert_true($calendar instanceof IntlCalendar, 'IntlCalendar::createInstance should return IntlCalendar');
    assert_same(true, $calendar->clear(), 'IntlCalendar clear should succeed');
    assert_false($calendar->isSet(IntlCalendar::FIELD_YEAR), 'IntlCalendar clear should unset fields');
    if (method_exists($calendar, 'setDate')) {
        $calendar->setDate(2024, 0, 15);
        assert_same(15, $calendar->get(IntlCalendar::FIELD_DATE), 'IntlCalendar setDate should set day-of-month');
        assert_same(true, $calendar->clear(), 'IntlCalendar clear should succeed after setDate');
    }
    if (method_exists($calendar, 'setDateTime')) {
        $calendar->setDateTime(2024, 1, 29, 12, 30, 0);
    } else {
        @$calendar->set(2024, 1, 29, 12, 30, 0);
    }
    assert_same(2024, $calendar->get(IntlCalendar::FIELD_YEAR), 'IntlCalendar year should be 2024');
    assert_same(1, $calendar->get(IntlCalendar::FIELD_MONTH), 'IntlCalendar month should be February zero-based');
    assert_same(29, $calendar->get(IntlCalendar::FIELD_DATE), 'IntlCalendar date should be 29');
    assert_same(1709209800000.0, $calendar->getTime(), 'IntlCalendar time should be epoch milliseconds');
    assert_same('2024-02-29 12:30:00', $calendar->toDateTime()->format('Y-m-d H:i:s'), 'IntlCalendar toDateTime should round-trip setDateTime');
    assert_same('gregorian', $calendar->getType(), 'IntlCalendar type should be gregorian');
    assert_contains('en', implode(',', IntlCalendar::getAvailableLocales()), 'IntlCalendar available locales should include English');
    assert_true(IntlCalendar::getNow() > 0, 'IntlCalendar::getNow should return current milliseconds');
    assert_true(is_string($calendar->getLocale(Locale::VALID_LOCALE)), 'IntlCalendar locale should return string');
    assert_same(IntlCalendar::DOW_SUNDAY, $calendar->getFirstDayOfWeek(), 'IntlCalendar default first day for en_US should be Sunday');
    assert_same(true, $calendar->setFirstDayOfWeek(IntlCalendar::DOW_MONDAY), 'IntlCalendar setFirstDayOfWeek should succeed');
    assert_same(IntlCalendar::DOW_MONDAY, $calendar->getFirstDayOfWeek(), 'IntlCalendar first day should round-trip');
    assert_same(true, $calendar->setMinimalDaysInFirstWeek(4), 'IntlCalendar setMinimalDaysInFirstWeek should succeed');
    assert_same(4, $calendar->getMinimalDaysInFirstWeek(), 'IntlCalendar minimal days should round-trip');
    assert_same(true, $calendar->setLenient(false), 'IntlCalendar setLenient should succeed');
    assert_false($calendar->isLenient(), 'IntlCalendar lenient flag should round-trip');
    assert_same(true, $calendar->setRepeatedWallTimeOption(IntlCalendar::WALLTIME_FIRST), 'IntlCalendar setRepeatedWallTimeOption should succeed');
    assert_same(IntlCalendar::WALLTIME_FIRST, $calendar->getRepeatedWallTimeOption(), 'IntlCalendar repeated wall time option should round-trip');
    assert_same(true, $calendar->setSkippedWallTimeOption(IntlCalendar::WALLTIME_LAST), 'IntlCalendar setSkippedWallTimeOption should succeed');
    assert_same(IntlCalendar::WALLTIME_LAST, $calendar->getSkippedWallTimeOption(), 'IntlCalendar skipped wall time option should round-trip');
    assert_same(true, $calendar->setTimeZone('America/New_York'), 'IntlCalendar setTimeZone should accept timezone IDs');
    assert_same('America/New_York', $calendar->getTimeZone()->getID(), 'IntlCalendar getTimeZone should expose new timezone');
    assert_same(true, $calendar->setTimeZone('UTC'), 'IntlCalendar setTimeZone should restore UTC');
    assert_false($calendar->inDaylightTime(), 'UTC calendar should not be in daylight saving time');
    assert_true(is_int($calendar->getDayOfWeekType(IntlCalendar::DOW_SUNDAY)), 'IntlCalendar day-of-week type should return int');
    assert_true($calendar->getWeekendTransition(IntlCalendar::DOW_SUNDAY) === false || is_int($calendar->getWeekendTransition(IntlCalendar::DOW_SUNDAY)), 'IntlCalendar weekend transition should return int or false');
    assert_true(is_bool($calendar->isWeekend(0.0)), 'IntlCalendar isWeekend should return bool for timestamp');
    assert_true($calendar->getActualMaximum(IntlCalendar::FIELD_DATE) >= 29, 'IntlCalendar actual maximum date should be at least 29');
    assert_true($calendar->getActualMinimum(IntlCalendar::FIELD_DATE) >= 1, 'IntlCalendar actual minimum date should be at least one');
    assert_true($calendar->getGreatestMinimum(IntlCalendar::FIELD_DATE) >= 1, 'IntlCalendar greatest minimum date should be at least one');
    assert_true($calendar->getLeastMaximum(IntlCalendar::FIELD_DATE) >= 28, 'IntlCalendar least maximum date should be at least 28');
    assert_true($calendar->getMinimum(IntlCalendar::FIELD_DATE) >= 1, 'IntlCalendar minimum date should be at least one');
    assert_true($calendar->getMaximum(IntlCalendar::FIELD_DATE) >= 31, 'IntlCalendar maximum date should be at least 31');
    assert_same(0, $calendar->getErrorCode(), 'IntlCalendar error code should be zero');
    assert_true(is_string($calendar->getErrorMessage()), 'IntlCalendar error message should return string');

    $keywordValues = [];
    $keywordIterator = IntlCalendar::getKeywordValuesForLocale('calendar', 'en_US', true);
    assert_true($keywordIterator instanceof IntlIterator, 'IntlCalendar keyword values should return IntlIterator');
    foreach ($keywordIterator as $value) {
        $keywordValues[] = $value;
    }
    assert_contains('gregorian', implode(',', $keywordValues), 'IntlCalendar keyword values should include gregorian');

    $start = IntlCalendar::createInstance('UTC', 'en_US');
    $end = IntlCalendar::createInstance('UTC', 'en_US');
    assert_true($start instanceof IntlCalendar && $end instanceof IntlCalendar, 'IntlCalendar comparison fixtures should initialize');
    $start->setTime(0.0);
    $end->setTime(86400000.0);
    assert_true($start->before($end), 'IntlCalendar before should compare timestamps');
    assert_true($end->after($start), 'IntlCalendar after should compare timestamps');
    assert_false($start->equals($end), 'IntlCalendar equals should detect different timestamps');
    assert_true($start->isEquivalentTo($end), 'IntlCalendar isEquivalentTo should compare calendar settings');
    assert_same(1, $start->fieldDifference(86400000.0, IntlCalendar::FIELD_DATE), 'IntlCalendar fieldDifference should calculate one day');
    assert_same(true, $start->add(IntlCalendar::FIELD_DATE, 1), 'IntlCalendar add should succeed');
    assert_same(true, $start->roll(IntlCalendar::FIELD_MONTH, 1), 'IntlCalendar roll should succeed');

    $fromDateTime = IntlCalendar::fromDateTime(new DateTime('2024-02-29 00:00:00 UTC'));
    assert_true($fromDateTime instanceof IntlCalendar, 'IntlCalendar::fromDateTime should accept DateTime');
    assert_same(2024, $fromDateTime->get(IntlCalendar::FIELD_YEAR), 'IntlCalendar::fromDateTime should set year');
    assert_true(intlcal_from_date_time(new DateTime('2024-02-29 00:00:00 UTC')) instanceof IntlCalendar, 'intlcal_from_date_time should return IntlCalendar');
    assert_true(intlcal_get_time_zone($calendar) instanceof IntlTimeZone, 'intlcal_get_time_zone should return IntlTimeZone');
    assert_same('gregorian', intlcal_get_type($calendar), 'intlcal_get_type should return gregorian');
    assert_same(0, intlcal_get_error_code($calendar), 'intlcal_get_error_code should be zero');
    assert_true(is_string(intlcal_get_error_message($calendar)), 'intlcal_get_error_message should return string');
    @intlcal_set($calendar, 2025, 0, 2, 0, 0, 0);
    assert_same(2025, intlcal_get($calendar, IntlCalendar::FIELD_YEAR), 'intlcal_set should set a date');

    $gregorian = method_exists(IntlGregorianCalendar::class, 'createFromDate')
        ? IntlGregorianCalendar::createFromDate(2024, 1, 29)
        : new IntlGregorianCalendar(2024, 1, 29);
    assert_true($gregorian instanceof IntlGregorianCalendar, 'IntlGregorianCalendar date constructor should return Gregorian calendar');
    assert_same('2024-02-29', $gregorian->toDateTime()->format('Y-m-d'), 'IntlGregorianCalendar date constructor should use zero-based months');
    assert_true($gregorian->isLeapYear(2024), 'IntlGregorianCalendar should detect leap year');
    $change = $gregorian->getGregorianChange();
    assert_true(is_float($change), 'IntlGregorianCalendar getGregorianChange should return float');
    assert_same(true, $gregorian->setGregorianChange($change), 'IntlGregorianCalendar setGregorianChange should succeed');
    $gregorianDateTime = method_exists(IntlGregorianCalendar::class, 'createFromDateTime')
        ? IntlGregorianCalendar::createFromDateTime(2024, 1, 29, 13, 45, 2)
        : new IntlGregorianCalendar(2024, 1, 29, 13, 45, 2);
    assert_true($gregorianDateTime instanceof IntlGregorianCalendar, 'IntlGregorianCalendar datetime constructor should return Gregorian calendar');
    assert_same('2024-02-29 13:45:02', $gregorianDateTime->toDateTime()->format('Y-m-d H:i:s'), 'IntlGregorianCalendar datetime constructor should keep time');
    assert_true(@intlgregcal_create_instance(IntlTimeZone::createTimeZone('UTC'), 'en_US') instanceof IntlGregorianCalendar, 'intlgregcal_create_instance should return Gregorian calendar');
    assert_true(intlgregcal_is_leap_year($gregorian, 2024), 'intlgregcal_is_leap_year should detect leap year');
    assert_same(true, intlgregcal_set_gregorian_change($gregorian, $change), 'intlgregcal_set_gregorian_change should succeed');
    assert_true(is_float(intlgregcal_get_gregorian_change($gregorian)), 'intlgregcal_get_gregorian_change should return float');
}

function test_intl_iterators_transliterator_spoof_resource_converter(): void
{
    $word = IntlBreakIterator::createWordInstance('en_US');
    assert_true($word instanceof IntlBreakIterator, 'IntlBreakIterator::createWordInstance should return iterator');
    assert_true($word->setText('Hello world'), 'IntlBreakIterator setText should succeed');
    assert_same(0, $word->first(), 'IntlBreakIterator first should return start');
    assert_same(5, $word->next(), 'IntlBreakIterator next should find first word boundary');
    assert_same(11, $word->following(6), 'IntlBreakIterator following should find boundary after offset');
    assert_same(5, $word->preceding(6), 'IntlBreakIterator preceding should find boundary before offset');
    assert_true($word->isBoundary(5), 'IntlBreakIterator isBoundary should detect boundary');
    assert_same(11, $word->last(), 'IntlBreakIterator last should return end');
    assert_same(6, $word->previous(), 'IntlBreakIterator previous should return prior boundary');
    assert_same(6, $word->current(), 'IntlBreakIterator current should return current boundary');
    assert_same('Hello world', $word->getText(), 'IntlBreakIterator getText should round-trip text');
    assert_true(is_string($word->getLocale(Locale::VALID_LOCALE)), 'IntlBreakIterator getLocale should return string');
    assert_same(0, $word->getErrorCode(), 'IntlBreakIterator error code should be zero');
    assert_true(is_string($word->getErrorMessage()), 'IntlBreakIterator error message should return string');
    $positions = [];
    foreach ($word->getIterator() as $position) {
        $positions[] = $position;
    }
    assert_contains('5', implode(',', $positions), 'IntlBreakIterator getIterator should expose boundary positions');
    $parts = $word->getPartsIterator(IntlPartsIterator::KEY_SEQUENTIAL);
    assert_true($parts instanceof IntlPartsIterator, 'IntlBreakIterator getPartsIterator should return IntlPartsIterator');
    $partValues = [];
    foreach ($parts as $part) {
        $partValues[] = $part;
        assert_true($parts->getBreakIterator() instanceof IntlBreakIterator, 'IntlPartsIterator getBreakIterator should return source break iterator');
        assert_true(is_int($parts->getRuleStatus()), 'IntlPartsIterator getRuleStatus should return int');
        break;
    }
    assert_same(['Hello'], $partValues, 'IntlPartsIterator should expose first word part');

    foreach ([
        'createCharacterInstance' => 'áb',
        'createLineInstance' => 'line wrap',
        'createSentenceInstance' => 'One. Two.',
        'createTitleInstance' => 'hello world',
    ] as $factory => $text) {
        $iterator = IntlBreakIterator::$factory('en_US');
        assert_true($iterator instanceof IntlBreakIterator, "IntlBreakIterator::{$factory} should create iterator");
        assert_true($iterator->setText($text), "IntlBreakIterator::{$factory} setText should succeed");
        assert_same(0, $iterator->first(), "IntlBreakIterator::{$factory} first should start at zero");
        assert_greater_than(0, $iterator->next(), "IntlBreakIterator::{$factory} next should advance");
    }

    $codePoint = IntlBreakIterator::createCodePointInstance();
    assert_true($codePoint instanceof IntlCodePointBreakIterator, 'IntlBreakIterator::createCodePointInstance should return codepoint iterator');
    assert_true($codePoint->setText("A\u{1F600}"), 'IntlCodePointBreakIterator setText should succeed');
    assert_same(0, $codePoint->first(), 'IntlCodePointBreakIterator first should return zero');
    assert_same(1, $codePoint->next(), 'IntlCodePointBreakIterator next should advance over ASCII code point');
    assert_same(0x41, $codePoint->getLastCodePoint(), 'IntlCodePointBreakIterator last code point should be A');
    assert_same(5, $codePoint->next(), 'IntlCodePointBreakIterator next should advance over emoji bytes');
    assert_same(0x1F600, $codePoint->getLastCodePoint(), 'IntlCodePointBreakIterator should expose emoji code point');

    $ruleBased = new IntlRuleBasedBreakIterator('!!chain; $letters = [[:L:]]+; $letters;');
    assert_true($ruleBased->setText('abc 123'), 'IntlRuleBasedBreakIterator setText should succeed');
    assert_same(0, $ruleBased->first(), 'IntlRuleBasedBreakIterator first should return zero');
    assert_same(3, $ruleBased->next(), 'IntlRuleBasedBreakIterator next should match letters rule');
    assert_same(0, $ruleBased->getRuleStatus(), 'IntlRuleBasedBreakIterator rule status should be zero');
    assert_same([0], $ruleBased->getRuleStatusVec(), 'IntlRuleBasedBreakIterator rule status vector should include zero');
    assert_true(is_string($ruleBased->getBinaryRules()) && strlen($ruleBased->getBinaryRules()) > 0, 'IntlRuleBasedBreakIterator binary rules should be available');
    assert_contains('letters', $ruleBased->getRules(), 'IntlRuleBasedBreakIterator rules should round-trip');

    $resource = ResourceBundle::create('en', null);
    assert_true($resource instanceof ResourceBundle, 'ResourceBundle::create should load ICU root bundle');
    assert_at_least(1, $resource->count(), 'ResourceBundle count should be positive');
    assert_same($resource->count(), resourcebundle_count($resource), 'resourcebundle_count should match OO count');
    assert_true($resource->get('calendar') instanceof ResourceBundle || is_array($resource->get('calendar')), 'ResourceBundle get should retrieve calendar data');
    assert_true(resourcebundle_get($resource, 'calendar') instanceof ResourceBundle || is_array(resourcebundle_get($resource, 'calendar')), 'resourcebundle_get should retrieve calendar data');
    $resourceKeys = [];
    foreach ($resource->getIterator() as $key => $value) {
        $resourceKeys[] = (string) $key;
        assert_true(is_scalar($value) || is_array($value) || $value instanceof ResourceBundle, 'ResourceBundle iterator should expose scalar, array, or bundle values');
        if (count($resourceKeys) >= 3) {
            break;
        }
    }
    assert_at_least(1, count($resourceKeys), 'ResourceBundle iterator should yield keys');
    $locales = @ResourceBundle::getLocales('');
    assert_true(is_array($locales) && in_array('en', $locales, true), 'ResourceBundle::getLocales should include en');
    $proceduralLocales = @resourcebundle_locales('');
    assert_true(is_array($proceduralLocales) && in_array('en', $proceduralLocales, true), 'resourcebundle_locales should include en');
    assert_same(0, $resource->getErrorCode(), 'ResourceBundle error code should be zero');
    assert_true(is_string($resource->getErrorMessage()), 'ResourceBundle error message should return string');
    assert_same(0, resourcebundle_get_error_code($resource), 'resourcebundle_get_error_code should be zero');
    assert_true(is_string(resourcebundle_get_error_message($resource)), 'resourcebundle_get_error_message should return string');

    $transliterator = Transliterator::create('Any-Latin; Latin-ASCII');
    assert_true($transliterator instanceof Transliterator, 'Transliterator::create should create transliterator');
    assert_same('Ecole dong jing', $transliterator->transliterate('École 東京'), 'Transliterator should transliterate accents and Han text');
    assert_same('Ecole dong jing', transliterator_transliterate('Any-Latin; Latin-ASCII', 'École 東京'), 'transliterator_transliterate should transliterate accents and Han text');
    $upper = Transliterator::createFromRules(':: Any-Upper;');
    assert_true($upper instanceof Transliterator, 'Transliterator::createFromRules should create transliterator');
    assert_same('ABC', $upper->transliterate('abc'), 'Transliterator rules should uppercase text');
    assert_true(transliterator_create_from_rules(':: Any-Upper;') instanceof Transliterator, 'transliterator_create_from_rules should create transliterator');
    assert_true($transliterator->createInverse() instanceof Transliterator, 'Transliterator createInverse should return transliterator');
    assert_true(transliterator_create_inverse($transliterator) instanceof Transliterator, 'transliterator_create_inverse should return transliterator');
    assert_true(is_array(Transliterator::listIDs()) && count(Transliterator::listIDs()) > 0, 'Transliterator::listIDs should return IDs');
    assert_true(is_array(transliterator_list_ids()) && count(transliterator_list_ids()) > 0, 'transliterator_list_ids should return IDs');
    assert_same(0, $transliterator->getErrorCode(), 'Transliterator error code should be zero');
    assert_true(is_string($transliterator->getErrorMessage()), 'Transliterator error message should return string');
    assert_same(0, transliterator_get_error_code($transliterator), 'transliterator_get_error_code should be zero');
    assert_true(is_string(transliterator_get_error_message($transliterator)), 'transliterator_get_error_message should return string');

    $spoof = new Spoofchecker();
    $spoofError = null;
    assert_true($spoof->isSuspicious('раураl', $spoofError), 'Spoofchecker should detect suspicious Cyrillic spoof text');
    assert_true(is_int($spoofError), 'Spoofchecker isSuspicious should set error code');
    assert_true($spoof->areConfusable('paypal', 'раураl', $spoofError), 'Spoofchecker should detect confusable strings');
    assert_true(is_int($spoofError), 'Spoofchecker areConfusable should set error code');
    $spoof->setAllowedLocales('en');
    $spoof->setChecks(Spoofchecker::SINGLE_SCRIPT_CONFUSABLE | Spoofchecker::MIXED_SCRIPT_CONFUSABLE);
    $spoof->setRestrictionLevel(Spoofchecker::HIGHLY_RESTRICTIVE);
    if (method_exists($spoof, 'setAllowedChars')) {
        $spoof->setAllowedChars('[a-z]');
    }
    assert_false($spoof->isSuspicious('paypal'), 'Spoofchecker should allow plain ASCII after allowed chars setup');

    $converter = new UConverter('ISO-8859-1', 'UTF-8');
    assert_same('e9', bin2hex($converter->convert('é')), 'UConverter should convert UTF-8 to ISO-8859-1');
    assert_same('ISO-8859-1', $converter->getDestinationEncoding(), 'UConverter destination encoding should round-trip');
    assert_same('UTF-8', $converter->getSourceEncoding(), 'UConverter source encoding should round-trip');
    assert_true(is_int($converter->getDestinationType()), 'UConverter destination type should return int');
    assert_true(is_int($converter->getSourceType()), 'UConverter source type should return int');
    assert_same(0, $converter->getErrorCode(), 'UConverter error code should be zero');
    assert_true(is_string($converter->getErrorMessage()), 'UConverter error message should return string');
    assert_true($converter->setSourceEncoding('ISO-8859-1'), 'UConverter setSourceEncoding should succeed');
    assert_true($converter->setDestinationEncoding('UTF-8'), 'UConverter setDestinationEncoding should succeed');
    assert_same('é', $converter->convert("\xE9"), 'UConverter should convert ISO-8859-1 to UTF-8');
    assert_same('e9', bin2hex(UConverter::transcode('é', 'ISO-8859-1', 'UTF-8')), 'UConverter::transcode should convert UTF-8 to ISO-8859-1');
    assert_same('é', UConverter::transcode("\xE9", 'UTF-8', 'ISO-8859-1'), 'UConverter::transcode should convert ISO-8859-1 to UTF-8');
    assert_true(in_array('UTF-8', UConverter::getAvailable(), true), 'UConverter::getAvailable should include UTF-8');
    assert_at_least(1, count(UConverter::getStandards() ?? []), 'UConverter::getStandards should return standards');
    assert_at_least(1, count(UConverter::getAliases('UTF-8') ?? []), 'UConverter::getAliases should return aliases');
    assert_true(is_string($converter->getSubstChars()), 'UConverter getSubstChars should return string');
    assert_true($converter->setSubstChars('?'), 'UConverter setSubstChars should succeed');
    assert_same('?', $converter->getSubstChars(), 'UConverter substitution chars should round-trip');
    assert_same('REASON_UNASSIGNED', UConverter::reasonText(UConverter::REASON_UNASSIGNED), 'UConverter reasonText should describe reason');
    $conversionError = 0;
    $fromCallback = $converter->fromUCallback(UConverter::REASON_UNASSIGNED, [], 0x2603, $conversionError);
    assert_true($fromCallback === null || is_array($fromCallback) || is_string($fromCallback) || is_int($fromCallback), 'UConverter fromUCallback should return documented types');
    assert_true(is_int($conversionError), 'UConverter fromUCallback should set error code');
    $conversionError = 0;
    $toCallback = $converter->toUCallback(UConverter::REASON_UNASSIGNED, '?', '?', $conversionError);
    assert_true($toCallback === null || is_array($toCallback) || is_string($toCallback) || is_int($toCallback), 'UConverter toUCallback should return documented types');
    assert_true(is_int($conversionError), 'UConverter toUCallback should set error code');
}

function test_tidy_configuration_and_repair(): void
{
    require_extension_loaded('tidy');
    assert_tidy_userland_manifest();
    assert_true(class_exists(tidy::class), 'tidy class should exist');
    assert_true(preg_match('/^\d{4}\/\d{2}\/\d{2}$/', tidy_get_release()) === 1, 'tidy_get_release should expose the libtidy release date');
    $tidyRi = getenv('WINLIBS_QA_TIDY_RI');
    if (is_string($tidyRi) && $tidyRi !== '' && is_file($tidyRi)) {
        $tidyRiText = (string) file_get_contents($tidyRi);
        $expectedTidyVersion = getenv('WINLIBS_QA_EXPECT_TIDY_VERSION');
        if (is_string($expectedTidyVersion) && $expectedTidyVersion !== '') {
            assert_contains('libTidy Version => ' . $expectedTidyVersion, $tidyRiText, "php --ri tidy should report libTidy {$expectedTidyVersion}");
        } else {
            assert_true(preg_match('/libTidy Version => \d+\.\d+\.\d+/', $tidyRiText) === 1, 'php --ri tidy should report libTidy version');
        }
    }

    $html = '<!doctype html><title>Winlibs</title><body><!--note--><p class=lead>hello <b>world';
    $config = [
        'indent' => true,
        'output-xhtml' => true,
        'wrap' => 0,
        'show-warnings' => true,
    ];
    $tidy = new tidy();
    assert_true($tidy->parseString($html, $config, 'utf8'), 'tidy parseString should succeed');
    assert_true($tidy->cleanRepair(), 'tidy cleanRepair should succeed');
    assert_true($tidy->diagnose(), 'tidy diagnose should succeed');
    $output = (string) $tidy;
    assert_true(preg_match('/<title>\s*Winlibs\s*<\/title>/i', $output) === 1, 'tidy output should preserve title');
    assert_contains('<p class="lead">', $output, 'tidy output should quote attributes');
    assert_same($output, tidy_get_output($tidy), 'tidy_get_output should match string cast');
    assert_true($tidy->getStatus() >= 0, 'tidy status should be available');
    assert_same($tidy->getStatus(), tidy_get_status($tidy), 'tidy_get_status should match OO status');
    assert_true(is_array($tidy->getConfig()), 'tidy getConfig should return an array');
    assert_true(is_array(tidy_get_config($tidy)), 'tidy_get_config should return an array');
    assert_true(is_int($tidy->getHtmlVer()), 'tidy getHtmlVer should return an integer');
    assert_same($tidy->getHtmlVer(), tidy_get_html_ver($tidy), 'tidy_get_html_ver should match OO value');
    assert_true(is_bool($tidy->isXhtml()), 'tidy isXhtml should return a boolean');
    assert_same($tidy->isXhtml(), tidy_is_xhtml($tidy), 'tidy_is_xhtml should match OO value');
    assert_false($tidy->isXml(), 'tidy isXml should be false for HTML input');
    assert_same($tidy->isXml(), tidy_is_xml($tidy), 'tidy_is_xml should match OO value');
    assert_true($tidy->getOpt('indent') === true || $tidy->getOpt('indent') === 1, 'tidy getOpt should return option value');
    assert_true(tidy_getopt($tidy, 'indent') === true || tidy_getopt($tidy, 'indent') === 1, 'tidy_getopt should return option value');
    assert_true($tidy->getOptDoc('indent') === false || is_string($tidy->getOptDoc('indent')), 'tidy getOptDoc should return docs or false');
    assert_true(tidy_get_opt_doc($tidy, 'indent') === false || is_string(tidy_get_opt_doc($tidy, 'indent')), 'tidy_get_opt_doc should return docs or false');
    assert_at_least(0, tidy_error_count($tidy), 'tidy_error_count should be non-negative');
    assert_at_least(0, tidy_warning_count($tidy), 'tidy_warning_count should be non-negative');
    assert_at_least(0, tidy_access_count($tidy), 'tidy_access_count should be non-negative');
    assert_at_least(0, tidy_config_count($tidy), 'tidy_config_count should be non-negative');
    assert_true(is_string(tidy_get_error_buffer($tidy)), 'tidy_get_error_buffer should return diagnostics text');
    assert_contains('missing', strtolower($tidy->errorBuffer), 'tidy diagnostics should mention repaired markup');

    $root = $tidy->root();
    $htmlNode = $tidy->html();
    $headNode = $tidy->head();
    $bodyNode = $tidy->body();
    assert_true($root instanceof tidyNode, 'tidy root node should exist');
    assert_true($htmlNode instanceof tidyNode, 'tidy html node should exist');
    assert_true($headNode instanceof tidyNode, 'tidy head node should exist');
    assert_true($bodyNode instanceof tidyNode, 'tidy body node should exist');
    assert_same($root->value, tidy_get_root($tidy)->value, 'tidy_get_root should match OO root');
    assert_same($htmlNode->name, tidy_get_html($tidy)->name, 'tidy_get_html should match OO html node');
    assert_same($headNode->name, tidy_get_head($tidy)->name, 'tidy_get_head should match OO head node');
    assert_same($bodyNode->name, tidy_get_body($tidy)->name, 'tidy_get_body should match OO body node');
    assert_true($root->hasChildren(), 'tidy root should have children');
    assert_false($root->hasSiblings(), 'tidy root should not have siblings');
    assert_true($htmlNode->isHtml(), 'tidy html node should report HTML');
    assert_true($headNode->hasSiblings(), 'tidy head node should have a body sibling');
    assert_true($bodyNode->getParent() instanceof tidyNode, 'tidy body node should expose a parent');
    if (method_exists($bodyNode, 'getPreviousSibling')) {
        assert_true($bodyNode->getPreviousSibling() instanceof tidyNode, 'tidy body node should expose previous sibling');
    }
    if (method_exists($bodyNode, 'getNextSibling')) {
        assert_true($bodyNode->getNextSibling() === null || $bodyNode->getNextSibling() instanceof tidyNode, 'tidy body next sibling should be null or a node');
    }
    $commentNode = find_tidy_node($root, static fn (object $node): bool => $node instanceof tidyNode && $node->isComment());
    assert_true($commentNode instanceof tidyNode, 'tidy tree should expose comment nodes');
    $textNode = find_tidy_node($root, static fn (object $node): bool => $node instanceof tidyNode && $node->isText());
    assert_true($textNode instanceof tidyNode, 'tidy tree should expose text nodes');
    assert_false($root->isAsp(), 'tidy root should not be an ASP node');
    assert_false($root->isJste(), 'tidy root should not be a JSTE node');
    assert_false($root->isPhp(), 'tidy root should not be a PHP node');
    expect_throwable(Error::class, static fn () => new tidyNode(), 'tidyNode cannot be directly constructed');

    $repaired = tidy_repair_string('<ul><li>one<li>two</ul>', ['output-xhtml' => true, 'wrap' => 0], 'utf8');
    assert_contains('<li>one</li>', $repaired, 'tidy_repair_string should close list items');
    assert_contains('<li>two</li>', $tidy->repairString('<ul><li>one<li>two</ul>', ['output-xhtml' => true, 'wrap' => 0], 'utf8'), 'tidy::repairString should close list items');

    $tmp = make_temp_dir('winlibs-tidy');
    try {
        $file = $tmp . DIRECTORY_SEPARATOR . 'input.html';
        file_put_contents($file, '<html><body><h1>File parse<p>body');
        $fromFile = tidy_parse_file($file, ['show-body-only' => true, 'wrap' => 0], 'utf8');
        assert_true($fromFile instanceof tidy, 'tidy_parse_file should return tidy object');
        $fromFile->cleanRepair();
        assert_contains('<h1>File parse</h1>', (string) $fromFile, 'tidy_parse_file should repair file markup');
        $ooFile = new tidy();
        assert_true($ooFile->parseFile($file, ['show-body-only' => true, 'wrap' => 0], 'utf8'), 'tidy::parseFile should parse files');
        assert_true($ooFile->cleanRepair(), 'tidy::parseFile result should repair');
        assert_contains('<p>body</p>', (string) $ooFile, 'tidy::parseFile should repair paragraphs');
        $repairedFile = tidy_repair_file($file, ['show-body-only' => true, 'wrap' => 0], 'utf8');
        assert_contains('<h1>File parse</h1>', $repairedFile, 'tidy_repair_file should repair file markup');
        assert_contains('<p>body</p>', $tidy->repairFile($file, ['show-body-only' => true, 'wrap' => 0], 'utf8'), 'tidy::repairFile should repair file markup');
    } finally {
        rrmdir($tmp);
    }
}

function test_readline_wineditline_surface(): void
{
    if (!extension_loaded('readline')) {
        assert_true(find_build_file('php_readline.dll') === null, 'php_readline.dll is present but the readline extension is not loaded');
        suite_info('readline extension is not present in this PHP artifact; no userland wineditline API is exposed');
        return;
    }

    assert_readline_userland_manifest();

    $info = readline_info();
    assert_true(is_array($info), 'readline_info should return an array');
    assert_true(array_key_exists('line_buffer', $info), 'readline_info should include line_buffer');
    readline_info('line_buffer', 'winlibs');
    assert_same('winlibs', readline_info('line_buffer'), 'readline_info line_buffer should round-trip');
    readline_info('line_buffer', '');
    assert_true(readline_clear_history(), 'readline_clear_history should succeed');
    $hasListHistory = function_exists('readline_list_history');
    if ($hasListHistory) {
        assert_same([], readline_list_history(), 'readline history should clear');
    } else {
        suite_info('readline_list_history is not available in this build');
    }
    assert_true(readline_add_history('first command'), 'readline_add_history first command should succeed');
    assert_true(readline_add_history('second command'), 'readline_add_history second command should succeed');
    if ($hasListHistory) {
        assert_same(['first command', 'second command'], readline_list_history(), 'readline_list_history should preserve order');
    }

    $tmp = make_temp_dir('winlibs-readline');
    try {
        $history = $tmp . DIRECTORY_SEPARATOR . 'history.txt';
        assert_true(readline_write_history($history), 'readline_write_history should succeed');
        $historyFile = str_replace(["\r\n", "\r"], "\n", (string) file_get_contents($history));
        $historyFile = str_replace('\\040', ' ', $historyFile);
        assert_contains("first command\n", $historyFile, 'readline_write_history should write the first entry');
        assert_contains("second command\n", $historyFile, 'readline_write_history should write the second entry');
        assert_true(readline_clear_history(), 'readline_clear_history should succeed before read_history');
        assert_true(readline_read_history($history), 'readline_read_history should succeed');
        if ($hasListHistory) {
            assert_same(['first command', 'second command'], readline_list_history(), 'readline_read_history should restore entries');
        }
    } finally {
        rrmdir($tmp);
    }

    assert_true(readline_completion_function(static fn (string $input, int $index): array => ['alpha', 'artifact']), 'readline_completion_function should accept a callback');
    if (function_exists('readline_callback_handler_install')) {
        $installed = @readline_callback_handler_install('qa> ', static function (?string $line): void {});
        assert_true(is_bool($installed), 'readline callback handler install should return a boolean in CI');
        if ($installed) {
            if (function_exists('readline_callback_read_char')) {
                readline_callback_read_char();
            }
            if (function_exists('readline_redisplay')) {
                readline_redisplay();
            }
            if (function_exists('readline_on_new_line')) {
                readline_on_new_line();
            }
            assert_true(readline_callback_handler_remove(), 'readline_callback_handler_remove should succeed');
        }
    }

    [$exitCode, $stdout, $stderr] = run_php_code_with_stdin(
        'if (!extension_loaded("readline")) { exit(2); } $line = readline("qa> "); echo json_encode($line), "\n";',
        "typed line\n"
    );
    assert_same(0, $exitCode, 'Child readline() process should exit successfully: ' . $stderr);
    assert_contains('"typed line"', $stdout, 'readline() should read a line from piped stdin');
}

$options = parse_options($argv);
$GLOBALS['suiteOptions'] = $options;
$metadata = [
    'php_version' => PHP_VERSION,
    'php_version_id' => PHP_VERSION_ID,
    'php_binary' => PHP_BINARY,
    'php_sapi' => PHP_SAPI,
    'php_os_family' => PHP_OS_FAMILY,
    'php_int_size' => PHP_INT_SIZE,
    'php_zts' => PHP_ZTS,
    'artifact' => $options['artifact'] ?? '',
    'arch' => $options['arch'] ?? '',
    'ts' => $options['ts'] ?? '',
    'vs' => $options['vs'] ?? '',
    'run_id' => $options['run-id'] ?? '',
    'run_title' => $options['run-title'] ?? '',
    'php_target' => $options['php-target'] ?? '',
    'build_dir' => getenv('WINLIBS_QA_BUILD_DIR') ?: '',
    'php_ini' => getenv('WINLIBS_QA_PHP_INI') ?: '',
    'intl_ri' => getenv('WINLIBS_QA_INTL_RI') ?: '',
    'tidy_ri' => getenv('WINLIBS_QA_TIDY_RI') ?: '',
    'enchant_module_path' => getenv('ENCHANT_MODULE_PATH') ?: '',
    'dicpath' => getenv('DICPATH') ?: '',
];

$suite = new TestSuite();
$suite->add('environment/configuration/defaults', fn () => test_environment($options));
$suite->add('curl/configuration/features/protocols', 'test_curl_configuration');
$suite->add('curl/http/basic/advanced/multi/share', 'test_curl_http_surface');
$suite->add('curl/file/error/encoding-helpers', 'test_curl_file_error_and_encoding_helpers');
$suite->add('ffi/configuration/memory/types', 'test_ffi_configuration_and_memory');
$suite->add('ffi/kernel32-foreign-calls', 'test_ffi_kernel32_calls');
$suite->add('glib/ffi-runtime/utf8/path/version', 'test_glib_runtime_via_ffi');
$suite->add('enchant/configuration/dictionaries/pwl', 'test_enchant_configuration_and_dictionary');
$suite->add('intl/configuration/icu-version/manifest', 'test_intl_configuration_and_manifest');
$suite->add('intl/locale/grapheme/normalizer/char/idn', 'test_intl_locale_grapheme_normalizer_char_idn');
$suite->add('intl/collator/number/message/date', 'test_intl_collator_number_message_date');
$suite->add('intl/calendar/timezone', 'test_intl_calendar_timezone');
$suite->add('intl/breakiterator/transliterator/spoof/resource/uconverter', 'test_intl_iterators_transliterator_spoof_resource_converter');
$suite->add('gd-libjpeg/configuration', 'test_gd_jpeg_configuration');
$suite->add('gd-libjpeg/encode/decode/progressive/errors', 'test_gd_jpeg_encoding_decoding_and_markers');
$suite->add('tidy/configuration/repair/tree/file', 'test_tidy_configuration_and_repair');
$suite->add('wineditline-readline/configuration/history/callbacks', 'test_readline_wineditline_surface');

exit($suite->run(
    isset($options['junit']) ? (string) $options['junit'] : null,
    isset($options['json']) ? (string) $options['json'] : null,
    $metadata
));
