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
    $path = tempnam(sys_get_temp_dir(), 'ffi-php-build-child-');
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
typedef unsigned char uint8_t;
typedef short int16_t;
typedef int int32_t;
typedef long long int64_t;
typedef unsigned long long uint64_t;

typedef struct plain_pair {
    int32_t a;
    double b;
} plain_pair;

typedef struct plain_small {
    uint8_t a;
    uint8_t b;
} plain_small;

typedef struct plain_big {
    int32_t a;
    int32_t b;
    int32_t c;
    int32_t d;
    int32_t e;
    int32_t f;
    int32_t g;
    int32_t h;
} plain_big;

typedef struct plain_single {
    int32_t value;
} plain_single;

typedef struct plain_nested_inner {
    int32_t value;
} plain_nested_inner;

typedef struct plain_nested {
    plain_nested_inner inner;
    double weight;
} plain_nested;

const char *plain_marker(void);
int32_t plain_add(int32_t left, int32_t right);
double plain_mix(int32_t left, double middle, int64_t right);
uint8_t plain_return_u8(uint8_t value);
int16_t plain_return_s16(int16_t value);
int64_t plain_return_s64(int64_t value);
plain_pair plain_make_pair(int32_t left, double right);
double plain_sum_pair(plain_pair value);
plain_small plain_make_small(uint8_t left, uint8_t right);
int32_t plain_sum_small(plain_small value);
plain_big plain_make_big(int32_t seed);
int32_t plain_sum_big(plain_big value);
plain_single plain_make_single(int32_t value);
int32_t plain_unbox_single(plain_single value);
plain_nested plain_make_nested(int32_t value, double weight);
double plain_sum_nested(plain_nested value);
int plain_fill_buffer(char *buffer, size_t capacity);
int plain_call_unary_callback(int (*callback)(int), int value);
int plain_sum_varargs_int(int count, ...);
double plain_sum_varargs_double(int count, ...);
double plain_gp_sse_mix(int32_t a, uint64_t b, float c, double d);
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

\$targetDll = \$argv[1] ?? '';
\$arch = \$argv[2] ?? '';
\$cdef = $cdef;

try {
    \$ffi = FFI::cdef(\$cdef, \$targetDll);
    $body
} catch (Throwable \$e) {
    emit_result(false, \$e->getMessage());
}
PHP;
}

function run_child_result(array &$results, string $group, string $name, string $body, string $targetDll, string $arch): void
{
    [$exitCode, $stdout, $stderr] = run_php_child(child_script($body), [$targetDll, $arch]);
    $payload = decode_child_payload($stdout);

    if (is_array($payload)) {
        add_result(
            $results,
            $group,
            $name,
            !empty($payload['pass']) && $exitCode === 0,
            (string) ($payload['detail'] ?? '')
        );
        return;
    }

    $detail = trim_detail('exit=' . $exitCode . ' output=' . trim($stdout . "\n" . $stderr));
    add_result($results, $group, $name, false, $detail);
}

if ($argc < 7) {
    fwrite(STDERR, "Usage: php php_artifact_ffi_runtime.php <target.dll> <php-input> <arch> <ts> <artifact-name> <source-run-id>\n");
    exit(2);
}

$targetDll = $argv[1];
$phpVersionInput = $argv[2];
$arch = $argv[3];
$threadSafety = $argv[4];
$artifactName = $argv[5];
$sourceRunId = $argv[6];
$results = [];

add_result($results, 'php-runtime', 'ffi-extension-loaded', extension_loaded('FFI'), PHP_VERSION);
add_result($results, 'php-runtime', 'ffi-class-present', class_exists(FFI::class), 'FFI class available');
add_result($results, 'php-runtime', 'ffi-enabled-for-cli', ini_get('ffi.enable') !== '0', 'ffi.enable=' . (string) ini_get('ffi.enable'));
add_result($results, 'php-runtime', 'thread-safety-matches-artifact', ((bool) PHP_ZTS) === ($threadSafety === 'ts'), 'PHP_ZTS=' . PHP_ZTS . ', expected=' . $threadSafety);

if (!extension_loaded('FFI') || !class_exists(FFI::class)) {
    $failures = array_values(array_filter($results, static fn(array $result): bool => !$result['pass']));
    echo json_encode([
        'php_input' => $phpVersionInput,
        'php_version' => PHP_VERSION,
        'php_sapi' => PHP_SAPI,
        'php_int_size' => PHP_INT_SIZE,
        'arch' => $arch,
        'ts' => $threadSafety,
        'artifact' => $artifactName,
        'source_run_id' => $sourceRunId,
        'os' => PHP_OS_FAMILY,
        'results' => $results,
        'failures' => count($failures),
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(1);
}

run_child_result($results, 'php-ffi-load', 'plain-target-dll', <<<'PHP'
$rawMarker = $ffi->plain_marker();
$marker = is_string($rawMarker) ? $rawMarker : FFI::string($rawMarker);
emit_result($marker === 'php-ffi-plain-target', $marker);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-calls', 'scalar-add', <<<'PHP'
$actual = $ffi->plain_add(40, 2);
emit_result($actual === 42, (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-calls', 'mixed-scalar-call', <<<'PHP'
$actual = $ffi->plain_mix(-4, 1.5, 45);
emit_result(same_float($actual, 42.5), (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-calls', 'small-unsigned-return', <<<'PHP'
$actual = $ffi->plain_return_u8(41);
emit_result($actual === 42, (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-calls', 'small-signed-return', <<<'PHP'
$actual = $ffi->plain_return_s16(-40);
emit_result($actual === -42, (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-calls', 'int64-return', <<<'PHP'
$input = PHP_INT_SIZE === 8 ? -900719925473958 : -1000000000;
$expected = $input + 42;
$actual = $ffi->plain_return_s64($input);
emit_result($actual === $expected, 'actual=' . $actual . ', expected=' . $expected);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-calls', 'gp-sse-register-mix', <<<'PHP'
$actual = $ffi->plain_gp_sse_mix(-7, 40, 2.25, 6.75);
emit_result(same_float($actual, 42.0), (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-varargs', 'int-sum', <<<'PHP'
$actual = $ffi->plain_sum_varargs_int(3, 10, 20, 12);
emit_result($actual === 42, (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-varargs', 'double-sum', <<<'PHP'
$actual = $ffi->plain_sum_varargs_double(3, 1.25, 2.50, 3.75);
emit_result(same_float($actual, 7.5), (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-structs', 'return-struct', <<<'PHP'
$pair = $ffi->plain_make_pair(33, 9.25);
emit_result($pair->a === 33 && same_float($pair->b, 9.25), 'a=' . $pair->a . ', b=' . $pair->b);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-structs', 'pass-struct-by-value', <<<'PHP'
$pair = $ffi->plain_make_pair(33, 9.25);
$actual = $ffi->plain_sum_pair($pair);
emit_result(same_float($actual, 42.25), (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-structs', 'small-struct', <<<'PHP'
$small = $ffi->plain_make_small(19, 23);
$actual = $ffi->plain_sum_small($small);
emit_result($small->a === 19 && $small->b === 23 && $actual === 42, 'a=' . $small->a . ', b=' . $small->b . ', sum=' . $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-structs', 'big-struct', <<<'PHP'
$big = $ffi->plain_make_big(1);
$actual = $ffi->plain_sum_big($big);
emit_result($actual === 36, (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-structs', 'single-entry-struct', <<<'PHP'
$single = $ffi->plain_make_single(42);
$actual = $ffi->plain_unbox_single($single);
emit_result($single->value === 42 && $actual === 42, 'value=' . $single->value . ', unboxed=' . $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-structs', 'nested-struct', <<<'PHP'
$nested = $ffi->plain_make_nested(30, 12.25);
$actual = $ffi->plain_sum_nested($nested);
emit_result($nested->inner->value === 30 && same_float($nested->weight, 12.25) && same_float($actual, 42.25), 'value=' . $nested->inner->value . ', weight=' . $nested->weight . ', sum=' . $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-memory', 'write-and-read-buffer', <<<'PHP'
$buffer = $ffi->new('char[64]');
$written = $ffi->plain_fill_buffer(FFI::addr($buffer[0]), FFI::sizeof($buffer));
$text = FFI::string($buffer);
emit_result($written === strlen('php-ffi-buffer-ok') && $text === 'php-ffi-buffer-ok', $text);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-memory', 'array-access-and-size', <<<'PHP'
$array = $ffi->new('int[4]');
for ($i = 0; $i < 4; $i++) {
    $array[$i] = $i + 1;
}
emit_result($array[2] === 3 && FFI::sizeof($array) === 16, 'C array access and sizeof');
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-callbacks', 'php-closure-to-c-callback', <<<'PHP'
$callback = static function (int $value): int {
    return ($value * 3) + 1;
};
$actual = $ffi->plain_call_unary_callback($callback, 12);
emit_result($actual === 42, (string) $actual);
PHP, $targetDll, $arch);

run_child_result($results, 'php-ffi-calling-conventions', 'winapi-get-current-process-id', <<<'PHP'
$kernel32 = FFI::cdef('unsigned long GetCurrentProcessId(void);', 'kernel32.dll');
$pid = $kernel32->GetCurrentProcessId();
emit_result($pid > 0, 'pid=' . $pid);
PHP, $targetDll, $arch);

$failures = array_values(array_filter($results, static fn(array $result): bool => !$result['pass']));

echo json_encode([
    'php_input' => $phpVersionInput,
    'php_version' => PHP_VERSION,
    'php_sapi' => PHP_SAPI,
    'php_int_size' => PHP_INT_SIZE,
    'arch' => $arch,
    'ts' => $threadSafety,
    'artifact' => $artifactName,
    'source_run_id' => $sourceRunId,
    'os' => PHP_OS_FAMILY,
    'results' => $results,
    'failures' => count($failures),
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;

exit(count($failures) === 0 ? 0 : 1);
