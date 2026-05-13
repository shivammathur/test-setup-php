<?php

declare(strict_types=1);

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

function same_float(float $left, float $right): bool
{
    return abs($left - $right) < 0.000001;
}

add_result($results, 'php-runtime', 'ffi-extension-loaded', extension_loaded('FFI'), PHP_VERSION);
add_result($results, 'php-runtime', 'ffi-class-present', class_exists(FFI::class), 'FFI class available');
add_result($results, 'php-runtime', 'ffi-enabled-for-cli', ini_get('ffi.enable') !== '0', 'ffi.enable=' . (string) ini_get('ffi.enable'));

if (!extension_loaded('FFI') || !class_exists(FFI::class)) {
    echo json_encode([
        'php_input' => $phpVersionInput,
        'php_version' => PHP_VERSION,
        'arch' => $arch,
        'artifact' => $artifactName,
        'results' => $results,
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(1);
}

$sizeType = PHP_INT_SIZE === 8 ? 'unsigned long long' : 'unsigned int';

$cdef = <<<CDEF
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

try {
    $ffi = FFI::cdef($cdef, $probeDll);
    add_result($results, 'php-runtime', 'load-probe-dll', true, $probeDll);
} catch (Throwable $e) {
    add_result($results, 'php-runtime', 'load-probe-dll', false, $e->getMessage());
    echo json_encode([
        'php_input' => $phpVersionInput,
        'php_version' => PHP_VERSION,
        'arch' => $arch,
        'artifact' => $artifactName,
        'results' => $results,
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
    exit(1);
}

$rawVersion = $ffi->probe_libffi_version();
$version = is_string($rawVersion) ? $rawVersion : FFI::string($rawVersion);
add_result($results, 'artifact-metadata-via-php', 'version-string', $version === '3.5.2', $version);
add_result($results, 'artifact-metadata-via-php', 'version-number', $ffi->probe_libffi_version_number() === 30502, (string) $ffi->probe_libffi_version_number());
add_result($results, 'artifact-metadata-via-php', 'default-abi', $ffi->probe_default_abi() > 0, (string) $ffi->probe_default_abi());
add_result($results, 'artifact-metadata-via-php', 'closure-size', $ffi->probe_closure_size() > 0, (string) $ffi->probe_closure_size());

add_result($results, 'php-ffi-calls', 'scalar-add', $ffi->probe_add(40, 2) === 42, 'cdecl int call');
add_result($results, 'php-ffi-calls', 'mixed-scalar-call', same_float($ffi->probe_mix(-4, 1.5, 45), 42.5), 'int/double/int64 call');

$pair = $ffi->probe_make_pair(33, 9.25);
add_result($results, 'php-ffi-structs', 'return-struct', $pair->a === 33 && same_float($pair->b, 9.25), 'struct returned from DLL');
add_result($results, 'php-ffi-structs', 'pass-struct-by-value', same_float($ffi->probe_sum_pair($pair), 42.25), 'struct passed back by value');
$single = $ffi->probe_make_single(42);
add_result($results, 'php-ffi-structs', 'return-single-entry-struct', $single->value === 42, 'single-entry struct returned from DLL');
add_result($results, 'php-ffi-structs', 'pass-single-entry-struct', $ffi->probe_unbox_single($single) === 42, 'single-entry struct passed by value');
$nested = $ffi->probe_make_nested(30, 12.25);
add_result($results, 'php-ffi-structs', 'return-nested-struct', $nested->inner->value === 30 && same_float($nested->weight, 12.25), 'nested struct returned from DLL');
add_result($results, 'php-ffi-structs', 'pass-nested-struct', same_float($ffi->probe_sum_nested($nested), 42.25), 'nested struct passed by value');

$buffer = FFI::new('char[64]');
$written = $ffi->probe_fill_buffer(FFI::addr($buffer[0]), FFI::sizeof($buffer));
add_result($results, 'php-ffi-memory', 'write-and-read-buffer', $written === strlen('ffi-buffer-ok') && FFI::string($buffer) === 'ffi-buffer-ok', FFI::string($buffer));

$array = FFI::new('int[4]');
for ($i = 0; $i < 4; $i++) {
    $array[$i] = $i + 1;
}
$ptr = FFI::addr($array[0]);
add_result($results, 'php-ffi-memory', 'array-pointer-cast', $ptr[2] === 3 && FFI::sizeof($array) === 16, 'C array and pointer access');

$callbackOk = false;
try {
    $callback = static function (int $value): int {
        return ($value * 3) + 1;
    };
    $callbackOk = $ffi->probe_call_unary_callback($callback, 12) === 42;
    add_result($results, 'php-ffi-callbacks', 'php-closure-to-c-callback', $callbackOk, 'PHP closure converted to C callback');
} catch (Throwable $e) {
    add_result($results, 'php-ffi-callbacks', 'php-closure-to-c-callback', false, $e->getMessage());
}

try {
    $kernel32 = FFI::cdef('unsigned long __stdcall GetCurrentProcessId(void);', 'kernel32.dll');
    add_result($results, 'php-ffi-calling-conventions', 'winapi-stdcall', $kernel32->GetCurrentProcessId() > 0, 'kernel32 GetCurrentProcessId');
} catch (Throwable $e) {
    add_result($results, 'php-ffi-calling-conventions', 'winapi-stdcall', false, $e->getMessage());
}

$dllSelfBuffer = FFI::new('char[1048576]');
$dllSelfFailures = $ffi->probe_run_all(FFI::addr($dllSelfBuffer[0]), FFI::sizeof($dllSelfBuffer));
add_result($results, 'artifact-self-via-php', 'dll-self-test-exit', $dllSelfFailures === 0, 'failures=' . $dllSelfFailures);
foreach (parse_line_results(FFI::string($dllSelfBuffer)) as $result) {
    $result['id'] = 'dll-' . $result['id'];
    $result['group'] = 'dll-' . $result['group'];
    $results[] = $result;
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
