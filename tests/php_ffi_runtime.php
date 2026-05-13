<?php

declare(strict_types=1);

ini_set('display_errors', 'stderr');

function add_result(array &$results, string $group, string $name, bool $pass, string $detail = ''): void
{
    $results[] = [
        'group' => $group,
        'name' => $name,
        'id' => $group . '/' . $name,
        'pass' => $pass,
        'detail' => $detail,
    ];
}

function parse_line_results(string $contents): array
{
    $parsed = [];
    foreach (preg_split('/\R/', trim($contents)) as $line) {
        if ($line === '') {
            continue;
        }
        $parts = explode('|', $line, 5);
        if (count($parts) !== 5 || $parts[0] !== 'RESULT') {
            $parsed[] = [
                'group' => 'artifact-self',
                'name' => 'line-protocol',
                'id' => 'artifact-self/line-protocol',
                'pass' => false,
                'detail' => 'Unparseable line: ' . $line,
            ];
            continue;
        }
        $parsed[] = [
            'group' => 'artifact-' . $parts[1],
            'name' => $parts[2],
            'id' => 'artifact-' . $parts[1] . '/' . $parts[2],
            'pass' => $parts[3] === 'PASS',
            'detail' => $parts[4],
        ];
    }
    return $parsed;
}

function trim_detail(string $detail): string
{
    $detail = trim(preg_replace('/\s+/', ' ', $detail) ?? $detail);
    if (strlen($detail) <= 500) {
        return $detail;
    }
    return substr($detail, 0, 497) . '...';
}

function run_php_child(string $code, array $args): array
{
    $path = tempnam(sys_get_temp_dir(), 'ffi-child-');
    if ($path === false) {
        return [1, '', 'tempnam failed'];
    }

    file_put_contents($path, $code);

    $command = escapeshellarg(PHP_BINARY) . ' -d display_errors=stderr ' . escapeshellarg($path);
    foreach ($args as $arg) {
        $command .= ' ' . escapeshellarg($arg);
    }

    $pipes = [];
    $process = proc_open($command, [
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ], $pipes);

    if (!is_resource($process)) {
        @unlink($path);
        return [1, '', 'proc_open failed'];
    }

    $stdout = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    @unlink($path);

    return [$exitCode, (string) $stdout, (string) $stderr];
}

function decode_child_payload(string $stdout): ?array
{
    foreach (preg_split('/\R/', trim($stdout)) as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] !== '{') {
            continue;
        }
        $payload = json_decode($line, true);
        if (is_array($payload)) {
            return $payload;
        }
    }
    return null;
}

function common_cdef(): string
{
    $sizeType = PHP_INT_SIZE === 8 ? 'unsigned long long' : 'unsigned int';

    return <<<CDEF
typedef $sizeType size_t;
typedef signed int int32_t;
typedef signed long long int64_t;

typedef struct probe_pair {
    int32_t a;
    double b;
} probe_pair;

typedef struct probe_single {
    int32_t value;
} probe_single;

typedef struct probe_nested_inner {
    int32_t value;
} probe_nested_inner;

typedef struct probe_nested {
    probe_nested_inner inner;
    double weight;
} probe_nested;

const char *probe_libffi_version(void);
unsigned long probe_libffi_version_number(void);
unsigned int probe_default_abi(void);
size_t probe_closure_size(void);
int probe_add(int left, int right);
double probe_mix(int32_t left, double middle, int64_t right);
probe_pair probe_make_pair(int32_t left, double right);
double probe_sum_pair(probe_pair value);
probe_single probe_make_single(int32_t value);
int32_t probe_unbox_single(probe_single value);
probe_nested probe_make_nested(int32_t value, double weight);
double probe_sum_nested(probe_nested value);
int probe_fill_buffer(char *buffer, size_t capacity);
int probe_call_unary_callback(int (*callback)(int), int value);
int probe_run_all(char *buffer, size_t capacity);
CDEF;
}

function child_script(string $body): string
{
    $cdef = var_export(common_cdef(), true);

    return <<<PHP
<?php
declare(strict_types=1);
ini_set('display_errors', 'stderr');

function emit_result(bool \$pass, string \$detail = '', array \$extra = []): void
{
    echo json_encode(['pass' => \$pass, 'detail' => \$detail] + \$extra, JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(\$pass ? 0 : 1);
}

function same_float(float \$left, float \$right): bool
{
    return abs(\$left - \$right) < 0.000001;
}

\$probeDll = \$argv[1] ?? '';
\$arch = \$argv[2] ?? '';
\$cdef = $cdef;

try {
    \$ffi = FFI::cdef(\$cdef, \$probeDll);
    $body
} catch (Throwable \$e) {
    emit_result(false, \$e->getMessage());
}
PHP;
}

function run_child_result(array &$results, string $group, string $name, string $body, string $probeDll, string $arch): ?array
{
    [$exitCode, $stdout, $stderr] = run_php_child(child_script($body), [$probeDll, $arch]);
    $payload = decode_child_payload($stdout);

    if (is_array($payload)) {
        add_result(
            $results,
            $group,
            $name,
            !empty($payload['pass']) && $exitCode === 0,
            (string) ($payload['detail'] ?? '')
        );
        return $payload;
    }

    $detail = trim_detail('exit=' . $exitCode . ' output=' . trim($stdout . "\n" . $stderr));
    add_result($results, $group, $name, false, $detail);
    return null;
}

if ($argc < 5) {
    fwrite(STDERR, "Usage: php php_ffi_runtime.php <probe.dll> <artifact-self.txt> <php-version> <arch> [artifact-name]\n");
    exit(2);
}

$probeDll = $argv[1];
$artifactSelfPath = $argv[2];
$phpVersionInput = $argv[3];
$arch = $argv[4];
$artifactName = $argv[5] ?? 'unknown';
$results = [];

add_result($results, 'php-runtime', 'ffi-extension-loaded', extension_loaded('FFI'), PHP_VERSION);
add_result($results, 'php-runtime', 'ffi-class-present', class_exists(FFI::class), 'FFI class available');
add_result($results, 'php-runtime', 'ffi-enabled-for-cli', ini_get('ffi.enable') !== '0', 'ffi.enable=' . (string) ini_get('ffi.enable'));

if (!extension_loaded('FFI') || !class_exists(FFI::class)) {
    $failures = array_values(array_filter($results, static fn(array $result): bool => !$result['pass']));
    echo json_encode([
        'php_input' => $phpVersionInput,
        'php_version' => PHP_VERSION,
        'php_sapi' => PHP_SAPI,
        'php_int_size' => PHP_INT_SIZE,
        'arch' => $arch,
        'artifact' => $artifactName,
        'os' => PHP_OS_FAMILY,
        'results' => $results,
        'failures' => count($failures),
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(1);
}

run_child_result($results, 'php-runtime', 'load-probe-dll', "emit_result(true, \$probeDll);", $probeDll, $arch);

run_child_result($results, 'artifact-metadata-via-php', 'version-string', <<<'PHP'
$rawVersion = $ffi->probe_libffi_version();
$version = is_string($rawVersion) ? $rawVersion : FFI::string($rawVersion);
emit_result($version === '3.5.2', $version);
PHP, $probeDll, $arch);

run_child_result($results, 'artifact-metadata-via-php', 'version-number', <<<'PHP'
$version = $ffi->probe_libffi_version_number();
emit_result($version === 30502, (string) $version);
PHP, $probeDll, $arch);

run_child_result($results, 'artifact-metadata-via-php', 'default-abi', <<<'PHP'
$defaultAbi = $ffi->probe_default_abi();
emit_result($defaultAbi > 0, (string) $defaultAbi);
PHP, $probeDll, $arch);

run_child_result($results, 'artifact-metadata-via-php', 'closure-size', <<<'PHP'
$closureSize = $ffi->probe_closure_size();
emit_result($closureSize > 0, (string) $closureSize);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-calls', 'scalar-add', <<<'PHP'
$actual = $ffi->probe_add(40, 2);
emit_result($actual === 42, (string) $actual);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-calls', 'mixed-scalar-call', <<<'PHP'
$actual = $ffi->probe_mix(-4, 1.5, 45);
emit_result(same_float($actual, 42.5), (string) $actual);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-structs', 'return-struct', <<<'PHP'
$pair = $ffi->probe_make_pair(33, 9.25);
emit_result($pair->a === 33 && same_float($pair->b, 9.25), 'a=' . $pair->a . ', b=' . $pair->b);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-structs', 'pass-struct-by-value', <<<'PHP'
$pair = $ffi->probe_make_pair(33, 9.25);
$actual = $ffi->probe_sum_pair($pair);
emit_result(same_float($actual, 42.25), (string) $actual);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-structs', 'return-single-entry-struct', <<<'PHP'
$single = $ffi->probe_make_single(42);
emit_result($single->value === 42, 'value=' . $single->value);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-structs', 'pass-single-entry-struct', <<<'PHP'
$single = $ffi->probe_make_single(42);
$actual = $ffi->probe_unbox_single($single);
emit_result($actual === 42, (string) $actual);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-structs', 'return-nested-struct', <<<'PHP'
$nested = $ffi->probe_make_nested(30, 12.25);
emit_result($nested->inner->value === 30 && same_float($nested->weight, 12.25), 'value=' . $nested->inner->value . ', weight=' . $nested->weight);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-structs', 'pass-nested-struct', <<<'PHP'
$nested = $ffi->probe_make_nested(30, 12.25);
$actual = $ffi->probe_sum_nested($nested);
emit_result(same_float($actual, 42.25), (string) $actual);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-memory', 'write-and-read-buffer', <<<'PHP'
$buffer = $ffi->new('char[64]');
$written = $ffi->probe_fill_buffer(FFI::addr($buffer[0]), FFI::sizeof($buffer));
$text = FFI::string($buffer);
emit_result($written === strlen('ffi-buffer-ok') && $text === 'ffi-buffer-ok', $text);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-memory', 'array-access-and-size', <<<'PHP'
$array = $ffi->new('int[4]');
for ($i = 0; $i < 4; $i++) {
    $array[$i] = $i + 1;
}
emit_result($array[2] === 3 && FFI::sizeof($array) === 16, 'C array access and sizeof');
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-callbacks', 'php-closure-to-c-callback', <<<'PHP'
$callback = static function (int $value): int {
    return ($value * 3) + 1;
};
$actual = $ffi->probe_call_unary_callback($callback, 12);
emit_result($actual === 42, (string) $actual);
PHP, $probeDll, $arch);

run_child_result($results, 'php-ffi-calling-conventions', 'winapi-get-current-process-id', <<<'PHP'
$kernel32 = FFI::cdef('unsigned long GetCurrentProcessId(void);', 'kernel32.dll');
$pid = $kernel32->GetCurrentProcessId();
emit_result($pid > 0, 'pid=' . $pid);
PHP, $probeDll, $arch);

$dllPayload = run_child_result($results, 'artifact-self-via-php', 'dll-self-test-exit', <<<'PHP'
$buffer = $ffi->new('char[1048576]');
$failures = $ffi->probe_run_all(FFI::addr($buffer[0]), FFI::sizeof($buffer));
emit_result($failures === 0, 'failures=' . $failures, ['lines' => FFI::string($buffer)]);
PHP, $probeDll, $arch);

if (isset($dllPayload['lines']) && is_string($dllPayload['lines'])) {
    foreach (parse_line_results($dllPayload['lines']) as $result) {
        $result['id'] = 'dll-' . $result['id'];
        $result['group'] = 'dll-' . $result['group'];
        $results[] = $result;
    }
}

$artifactSelf = is_file($artifactSelfPath) ? file_get_contents($artifactSelfPath) : '';
add_result($results, 'artifact-self-exe', 'output-present', trim((string) $artifactSelf) !== '', $artifactSelfPath);
foreach (parse_line_results((string) $artifactSelf) as $result) {
    $result['id'] = 'exe-' . $result['id'];
    $result['group'] = 'exe-' . $result['group'];
    $results[] = $result;
}

$failures = array_values(array_filter($results, static fn(array $result): bool => !$result['pass']));

echo json_encode([
    'php_input' => $phpVersionInput,
    'php_version' => PHP_VERSION,
    'php_sapi' => PHP_SAPI,
    'php_int_size' => PHP_INT_SIZE,
    'arch' => $arch,
    'artifact' => $artifactName,
    'os' => PHP_OS_FAMILY,
    'results' => $results,
    'failures' => count($failures),
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;

exit(count($failures) === 0 ? 0 : 1);
