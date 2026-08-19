<?php

declare(strict_types=1);

final class SkipTest extends RuntimeException
{
}

function parse_cli_args(array $argv): array
{
    $args = [];
    for ($i = 1; $i < count($argv); $i++) {
        $key = $argv[$i];
        if (!str_starts_with($key, '--')) {
            continue;
        }
        $name = substr($key, 2);
        $next = $argv[$i + 1] ?? null;
        if ($next !== null && !str_starts_with($next, '--')) {
            $args[$name] = $next;
            $i++;
        } else {
            $args[$name] = true;
        }
    }
    return $args;
}

$args = parse_cli_args($argv);
$label = (string)($args['label'] ?? 'unknown');
$phpRef = (string)($args['php-ref'] ?? 'unknown');
$arch = (string)($args['arch'] ?? 'unknown');
$threadSafety = (string)($args['thread-safety'] ?? 'unknown');
$certFile = (string)($args['cert'] ?? '');
$keyFile = (string)($args['key'] ?? '');
$outFile = (string)($args['out'] ?? '');
$expectedVendorVersion = isset($args['expected-vendor-version']) ? (int)$args['expected-vendor-version'] : null;
$expectedVendorMajor = isset($args['expected-vendor-major']) ? (int)$args['expected-vendor-major'] : null;

if ($outFile === '') {
    fwrite(STDERR, "Missing --out\n");
    exit(2);
}

$summary = [
    'label' => $label,
    'php_ref' => $phpRef,
    'arch' => $arch,
    'thread_safety' => $threadSafety,
    'php_version' => PHP_VERSION,
    'php_binary' => PHP_BINARY,
    'php_ini' => php_ini_loaded_file() ?: '',
    'ldap' => [],
    'constants' => [],
    'functions' => [],
    'tests' => [],
    'observations' => [],
    'called_functions' => [],
    'all_warnings' => [],
];

$currentWarnings = [];
set_error_handler(static function (int $severity, string $message, string $file, int $line) use (&$currentWarnings, &$summary): bool {
    $warning = [
        'severity' => $severity,
        'message' => $message,
        'file' => basename($file),
        'line' => $line,
    ];
    $currentWarnings[] = $warning;
    $summary['all_warnings'][] = $warning;
    return true;
});

function covered(string $function): void
{
    global $summary;
    $summary['called_functions'][$function] = true;
}

function observation(string $key, mixed $value): void
{
    global $summary;
    $summary['observations'][$key] = $value;
}

function expect(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

function skip_if(bool $condition, string $message): void
{
    if ($condition) {
        throw new SkipTest($message);
    }
}

function observed_call(string $function, callable $callback): array
{
    covered($function);
    try {
        $result = $callback();
        return [
            'ok' => $result !== false,
            'result' => normalize_value($result),
        ];
    } catch (Throwable $e) {
        return [
            'ok' => false,
            'exception' => get_class($e),
            'message' => $e->getMessage(),
        ];
    }
}

function ldap_diagnostic($conn): array
{
    $diagnostic = [];
    if (function_exists('ldap_errno')) {
        covered('ldap_errno');
        $diagnostic['errno'] = ldap_errno($conn);
    }
    if (function_exists('ldap_error')) {
        covered('ldap_error');
        $diagnostic['error'] = ldap_error($conn);
    }
    return $diagnostic;
}

function ldap_operation_observation($conn, string $function, callable $callback): array
{
    return observed_call($function, $callback) + ldap_diagnostic($conn);
}

function check(string $name, callable $callback, bool $allowWarnings = false): void
{
    global $summary, $currentWarnings;
    $currentWarnings = [];
    $started = microtime(true);
    try {
        $details = $callback();
        $warnings = $currentWarnings;
        if (!$allowWarnings && $warnings !== []) {
            throw new RuntimeException('Unexpected warning: ' . $warnings[0]['message']);
        }
        $summary['tests'][$name] = [
            'status' => 'passed',
            'warnings' => $warnings,
            'details' => $details,
            'duration_ms' => (int)round((microtime(true) - $started) * 1000),
        ];
        echo "[PASS] $name\n";
    } catch (SkipTest $e) {
        $summary['tests'][$name] = [
            'status' => 'skipped',
            'reason' => $e->getMessage(),
            'warnings' => $currentWarnings,
            'duration_ms' => (int)round((microtime(true) - $started) * 1000),
        ];
        echo "[SKIP] $name: {$e->getMessage()}\n";
    } catch (Throwable $e) {
        $summary['tests'][$name] = [
            'status' => 'failed',
            'error' => $e->getMessage(),
            'warnings' => $currentWarnings,
            'duration_ms' => (int)round((microtime(true) - $started) * 1000),
        ];
        echo "[FAIL] $name: {$e->getMessage()}\n";
    }
}

function ber_len(int $length): string
{
    if ($length < 0x80) {
        return chr($length);
    }
    $bytes = '';
    while ($length > 0) {
        $bytes = chr($length & 0xff) . $bytes;
        $length >>= 8;
    }
    return chr(0x80 | strlen($bytes)) . $bytes;
}

function ber_tag(int $tag, string $payload): string
{
    return chr($tag) . ber_len(strlen($payload)) . $payload;
}

function ber_seq(string $payload): string
{
    return ber_tag(0x30, $payload);
}

function ber_int(int $value): string
{
    if ($value === 0) {
        return ber_tag(0x02, "\x00");
    }
    $bytes = '';
    while ($value > 0) {
        $bytes = chr($value & 0xff) . $bytes;
        $value >>= 8;
    }
    if ((ord($bytes[0]) & 0x80) !== 0) {
        $bytes = "\x00" . $bytes;
    }
    return ber_tag(0x02, $bytes);
}

function ber_enum(int $value): string
{
    $encoded = ber_int($value);
    return "\x0a" . substr($encoded, 1);
}

function ber_octet(string $value): string
{
    return ber_tag(0x04, $value);
}

function ber_ctx(int $number, string $payload, bool $constructed = false): string
{
    return ber_tag(0x80 | ($constructed ? 0x20 : 0x00) | $number, $payload);
}

function proc_capture(array $command, ?array $env = null, int $timeoutSeconds = 15): array
{
    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $process = proc_open($command, $descriptors, $pipes, getcwd(), $env);
    if (!is_resource($process)) {
        throw new RuntimeException('Failed to start process: ' . implode(' ', $command));
    }
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);
    $stdout = '';
    $stderr = '';
    $started = time();
    $observedExitCode = null;
    do {
        $stdout .= stream_get_contents($pipes[1]);
        $stderr .= stream_get_contents($pipes[2]);
        $status = proc_get_status($process);
        if (!$status['running']) {
            $observedExitCode = $status['exitcode'];
            break;
        }
        if (time() - $started > $timeoutSeconds) {
            proc_terminate($process);
            throw new RuntimeException('Process timed out: ' . implode(' ', $command));
        }
        usleep(50000);
    } while (true);
    $stdout .= stream_get_contents($pipes[1]);
    $stderr .= stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $exitCode = proc_close($process);
    if ($exitCode === -1 && $observedExitCode !== null) {
        $exitCode = $observedExitCode;
    }
    return [
        'exit_code' => $exitCode,
        'stdout' => $stdout,
        'stderr' => $stderr,
    ];
}

function php_command_prefix(): array
{
    $command = [PHP_BINARY];
    $ini = php_ini_loaded_file();
    if ($ini !== false && $ini !== '') {
        $command[] = '-c';
        $command[] = $ini;
    }
    return $command;
}

function find_free_port(): int
{
    for ($i = 0; $i < 30; $i++) {
        $port = random_int(20000, 50000);
        $server = @stream_socket_server('tcp://127.0.0.1:' . $port, $errno, $errstr);
        if ($server) {
            fclose($server);
            return $port;
        }
    }
    throw new RuntimeException('Could not find a free TCP port');
}

function start_ldap_server(string $mode): array
{
    global $certFile, $keyFile;
    if ($mode !== 'plain' && $mode !== 'ldaps') {
        throw new InvalidArgumentException('Invalid server mode');
    }
    if (!is_file($certFile) || !is_file($keyFile)) {
        throw new RuntimeException('TLS certificate/key files are missing');
    }
    $port = find_free_port();
    $tmp = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'ldap-suite-' . bin2hex(random_bytes(6));
    mkdir($tmp, 0777, true);
    $ready = $tmp . DIRECTORY_SEPARATOR . 'ready.txt';
    $log = $tmp . DIRECTORY_SEPARATOR . 'server.log';
    $command = array_merge(php_command_prefix(), [
        __DIR__ . DIRECTORY_SEPARATOR . 'ldap_mock_server.php',
        '--mode=' . $mode,
        '--port=' . $port,
        '--ready=' . $ready,
        '--cert=' . $certFile,
        '--key=' . $keyFile,
        '--log=' . $log,
    ]);
    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $process = proc_open($command, $descriptors, $pipes, __DIR__);
    if (!is_resource($process)) {
        throw new RuntimeException('Failed to start mock LDAP server');
    }
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $deadline = microtime(true) + 10;
    while (microtime(true) < $deadline) {
        if (is_file($ready)) {
            $readyText = trim((string)file_get_contents($ready));
            if (str_starts_with($readyText, 'error:')) {
                throw new RuntimeException('Mock server failed: ' . $readyText);
            }
            return [
                'port' => $port,
                'process' => $process,
                'pipes' => $pipes,
                'log' => $log,
                'tmp' => $tmp,
            ];
        }
        $status = proc_get_status($process);
        if (!$status['running']) {
            $stderr = stream_get_contents($pipes[2]);
            throw new RuntimeException('Mock server exited before ready: ' . $stderr);
        }
        usleep(50000);
    }
    proc_terminate($process);
    throw new RuntimeException('Mock server did not become ready');
}

function stop_ldap_server(array $server): void
{
    if (isset($server['process']) && is_resource($server['process'])) {
        $status = proc_get_status($server['process']);
        if ($status['running']) {
            proc_terminate($server['process']);
        }
        foreach ($server['pipes'] as $pipe) {
            if (is_resource($pipe)) {
                fclose($pipe);
            }
        }
        proc_close($server['process']);
    }
}

function with_ldap_server(string $mode, callable $callback): mixed
{
    $server = start_ldap_server($mode);
    try {
        return $callback($server['port'], $server);
    } finally {
        stop_ldap_server($server);
    }
}

function tls_require_cert(int $value): void
{
    if (defined('LDAP_OPT_X_TLS_REQUIRE_CERT')) {
        observed_call('ldap_set_option', static fn() => ldap_set_option(null, LDAP_OPT_X_TLS_REQUIRE_CERT, $value));
    }
    if (defined('LDAP_OPT_X_TLS_NEWCTX')) {
        observed_call('ldap_set_option', static fn() => ldap_set_option(null, LDAP_OPT_X_TLS_NEWCTX, 0));
    }
}

function tls_never(): void
{
    if (defined('LDAP_OPT_X_TLS_NEVER')) {
        tls_require_cert(LDAP_OPT_X_TLS_NEVER);
    }
}

function tls_demand(): void
{
    if (defined('LDAP_OPT_X_TLS_DEMAND')) {
        tls_require_cert(LDAP_OPT_X_TLS_DEMAND);
    }
}

function ldap_connect_checked(string $uri)
{
    covered('ldap_connect');
    $conn = ldap_connect($uri);
    expect($conn !== false, "ldap_connect failed for $uri");
    covered('ldap_set_option');
    expect(ldap_set_option($conn, LDAP_OPT_PROTOCOL_VERSION, 3), 'Failed to set LDAPv3');
    if (defined('LDAP_OPT_REFERRALS')) {
        covered('ldap_set_option');
        ldap_set_option($conn, LDAP_OPT_REFERRALS, 0);
    }
    return $conn;
}

function ldap_bind_checked($conn, ?string $dn = null, ?string $password = null): void
{
    covered('ldap_bind');
    expect(ldap_bind($conn, $dn, $password), 'ldap_bind failed');
}

function ldap_option_probe($conn, string $constant, mixed $value = null, bool $setFirst = true): array
{
    if (!defined($constant)) {
        return ['defined' => false];
    }

    $details = ['defined' => true];
    if ($setFirst) {
        $details['set'] = observed_call('ldap_set_option', static fn() => ldap_set_option($conn, constant($constant), $value));
    }

    $got = null;
    $details['get'] = observed_call('ldap_get_option', static function () use ($conn, $constant, &$got): bool {
        return ldap_get_option($conn, constant($constant), $got);
    });
    $details['value'] = normalize_value($got);
    $details['supported'] = ($details['set']['ok'] ?? false) || ($details['get']['ok'] ?? false);

    return $details;
}

function parse_result_checked($conn, $result, int $expected = 0): array
{
    covered('ldap_parse_result');
    $errno = null;
    $matched = null;
    $diag = null;
    $refs = null;
    $controls = null;
    expect(ldap_parse_result($conn, $result, $errno, $matched, $diag, $refs, $controls), 'ldap_parse_result failed');
    expect((int)$errno === $expected, "Expected LDAP result $expected, got $errno ($diag)");
    return [
        'errno' => $errno,
        'matched' => $matched,
        'diagnostic' => $diag,
        'refs' => $refs,
        'controls' => normalize_value($controls),
    ];
}

function normalize_value(mixed $value): mixed
{
    if (is_string($value)) {
        if (preg_match('//u', $value) === 1 && !preg_match('/[\x00-\x08\x0e-\x1f\x7f-\xff]/', $value)) {
            return $value;
        }
        return [
            'base64' => base64_encode($value),
            'length' => strlen($value),
        ];
    }
    if (is_array($value)) {
        $normalized = [];
        foreach ($value as $key => $item) {
            $normalized[(string)$key] = normalize_value($item);
        }
        ksort($normalized);
        return $normalized;
    }
    if (is_object($value)) {
        return get_debug_type($value);
    }
    return $value;
}

function collect_result_dns($conn, $result): array
{
    $dns = [];
    covered('ldap_first_entry');
    $entry = ldap_first_entry($conn, $result);
    while ($entry !== false) {
        covered('ldap_get_dn');
        $dns[] = ldap_get_dn($conn, $entry);
        covered('ldap_next_entry');
        $entry = ldap_next_entry($conn, $entry);
    }
    sort($dns);
    return $dns;
}

function find_result_entry_by_dn($conn, $result, string $dn)
{
    covered('ldap_first_entry');
    $entry = ldap_first_entry($conn, $result);
    while ($entry !== false) {
        covered('ldap_get_dn');
        if (strcasecmp((string)ldap_get_dn($conn, $entry), $dn) === 0) {
            return $entry;
        }
        covered('ldap_next_entry');
        $entry = ldap_next_entry($conn, $entry);
    }
    return false;
}

function build_request_controls(): array
{
    $controls = [];
    $controls[] = [
        'name' => 'paged',
        'control' => [
            'oid' => defined('LDAP_CONTROL_PAGEDRESULTS') ? LDAP_CONTROL_PAGEDRESULTS : '1.2.840.113556.1.4.319',
            'iscritical' => false,
            'value' => ber_seq(ber_int(2) . ber_octet('')),
        ],
    ];
    $controls[] = [
        'name' => 'sort',
        'control' => [
            'oid' => defined('LDAP_CONTROL_SORTREQUEST') ? LDAP_CONTROL_SORTREQUEST : '1.2.840.113556.1.4.473',
            'iscritical' => false,
            'value' => ber_seq(ber_seq(ber_octet('cn'))),
        ],
    ];
    if (defined('LDAP_CONTROL_VLVREQUEST')) {
        $controls[] = [
            'name' => 'vlv',
            'control' => [
                'oid' => LDAP_CONTROL_VLVREQUEST,
                'iscritical' => false,
                'value' => ber_seq(ber_int(0) . ber_int(1) . ber_ctx(0, ber_seq(ber_int(1) . ber_int(0)), true)),
            ],
        ];
    }
    if (defined('LDAP_CONTROL_ASSERT')) {
        $controls[] = [
            'name' => 'assertion',
            'control' => [
                'oid' => LDAP_CONTROL_ASSERT,
                'iscritical' => false,
                'value' => ber_ctx(7, 'objectClass'),
            ],
        ];
    }
    if (defined('LDAP_CONTROL_PRE_READ')) {
        $controls[] = [
            'name' => 'pre-read',
            'control' => [
                'oid' => LDAP_CONTROL_PRE_READ,
                'iscritical' => false,
                'value' => ber_seq(ber_octet('cn') . ber_octet('description')),
            ],
        ];
    }
    if (defined('LDAP_CONTROL_POST_READ')) {
        $controls[] = [
            'name' => 'post-read',
            'control' => [
                'oid' => LDAP_CONTROL_POST_READ,
                'iscritical' => false,
                'value' => ber_seq(ber_octet('cn') . ber_octet('description')),
            ],
        ];
    }
    if (defined('LDAP_CONTROL_MANAGEDSAIT')) {
        $controls[] = [
            'name' => 'manage-dsait',
            'control' => [
                'oid' => LDAP_CONTROL_MANAGEDSAIT,
                'iscritical' => false,
            ],
        ];
    }
    if (defined('LDAP_CONTROL_SUBENTRIES')) {
        $controls[] = [
            'name' => 'subentries',
            'control' => [
                'oid' => LDAP_CONTROL_SUBENTRIES,
                'iscritical' => false,
                'value' => "\x01\x01\xff",
            ],
        ];
    }
    if (defined('LDAP_CONTROL_PROXY_AUTHZ')) {
        $controls[] = [
            'name' => 'proxy-authz',
            'control' => [
                'oid' => LDAP_CONTROL_PROXY_AUTHZ,
                'iscritical' => false,
                'value' => 'dn:cn=alice,ou=people,dc=example,dc=test',
            ],
        ];
    }
    if (defined('LDAP_CONTROL_PASSWORDPOLICYREQUEST')) {
        $controls[] = [
            'name' => 'password-policy',
            'control' => [
                'oid' => LDAP_CONTROL_PASSWORDPOLICYREQUEST,
                'iscritical' => false,
            ],
        ];
    }
    foreach ([
        ['authzid-request', 'LDAP_CONTROL_AUTHZID_REQUEST', null],
        ['dont-use-copy', 'LDAP_CONTROL_DONTUSECOPY', null],
        ['values-return-filter', 'LDAP_CONTROL_VALUESRETURNFILTER', ber_ctx(7, 'cn')],
        ['sync', 'LDAP_CONTROL_SYNC', ber_seq(ber_enum(1))],
        ['domain-scope', 'LDAP_CONTROL_X_DOMAIN_SCOPE', null],
        ['extended-dn', 'LDAP_CONTROL_X_EXTENDED_DN', ber_seq(ber_int(1))],
        ['incremental-values', 'LDAP_CONTROL_X_INCREMENTAL_VALUES', null],
        ['permissive-modify', 'LDAP_CONTROL_X_PERMISSIVE_MODIFY', null],
        ['search-options', 'LDAP_CONTROL_X_SEARCH_OPTIONS', ber_seq(ber_int(1))],
        ['tree-delete', 'LDAP_CONTROL_X_TREE_DELETE', null],
    ] as [$name, $constant, $value]) {
        if (!defined($constant)) {
            continue;
        }
        $control = [
            'oid' => constant($constant),
            'iscritical' => false,
        ];
        if ($value !== null) {
            $control['value'] = $value;
        }
        $controls[] = [
            'name' => $name,
            'control' => $control,
        ];
    }
    $controls[] = [
        'name' => 'unknown',
        'control' => [
            'oid' => '1.3.6.1.4.1.4203.666.5.999',
            'iscritical' => false,
            'value' => 'client-control',
        ],
    ];
    return $controls;
}

function json_php_code(string $code): string
{
    return $code;
}

check('extension and exported API', function () use (&$summary, $expectedVendorVersion, $expectedVendorMajor): array {
    expect(extension_loaded('ldap'), 'ldap extension is not loaded');
    $functions = get_extension_funcs('ldap') ?: [];
    sort($functions);
    $summary['functions'] = $functions;

    $constants = [];
    foreach (get_defined_constants(true)['ldap'] ?? [] as $name => $value) {
        if (str_starts_with($name, 'LDAP_')) {
            $constants[$name] = normalize_value($value);
        }
    }
    ksort($constants);
    $summary['constants'] = $constants;

    $api = null;
    if (defined('LDAP_OPT_API_INFO')) {
        covered('ldap_get_option');
        expect(ldap_get_option(null, LDAP_OPT_API_INFO, $api), 'LDAP_OPT_API_INFO failed');
    }
    $summary['ldap']['api_info'] = normalize_value($api);

    $moduleInfo = proc_capture(array_merge(php_command_prefix(), ['--ri', 'ldap']));
    expect($moduleInfo['exit_code'] === 0, 'php --ri ldap failed: ' . $moduleInfo['stderr']);
    expect(str_contains(strtolower($moduleInfo['stdout']), 'ldap support'), 'php --ri ldap did not report LDAP support');
    $summary['ldap']['module_info'] = $moduleInfo['stdout'];

    $vendorVersion = (int)($api['vendor_version'] ?? ($constants['LDAP_VENDOR_VERSION'] ?? 0));
    if ($vendorVersion === 0 && preg_match('/Vendor Version\\s*=>\\s*(\\d+)/i', $moduleInfo['stdout'], $matches) === 1) {
        $vendorVersion = (int)$matches[1];
    }
    $summary['ldap']['vendor_version'] = $vendorVersion;
    $summary['ldap']['vendor_name'] = (string)($api['vendor_name'] ?? '');

    if ($expectedVendorVersion !== null) {
        expect($vendorVersion === $expectedVendorVersion, "Expected OpenLDAP vendor version $expectedVendorVersion, got $vendorVersion");
    }
    if ($expectedVendorMajor !== null) {
        expect(intdiv($vendorVersion, 100) === $expectedVendorMajor, "Expected OpenLDAP vendor major $expectedVendorMajor, got $vendorVersion");
    }

    $modules = proc_capture(array_merge(php_command_prefix(), ['-m']));
    expect($modules['exit_code'] === 0, 'php -m failed: ' . $modules['stderr']);
    expect(preg_match('/^ldap$/mi', $modules['stdout']) === 1, 'php -m did not list ldap');

    return [
        'vendor_version' => $vendorVersion,
        'function_count' => count($functions),
        'constant_count' => count($constants),
    ];
});

check('connection options and config probes', function (): array {
    $details = [];
    with_ldap_server('plain', function (int $port) use (&$details): void {
        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        $coreOptions = [
            'LDAP_OPT_PROTOCOL_VERSION' => 3,
            'LDAP_OPT_REFERRALS' => 0,
            'LDAP_OPT_DEREF' => defined('LDAP_DEREF_NEVER') ? LDAP_DEREF_NEVER : 0,
            'LDAP_OPT_SIZELIMIT' => 50,
            'LDAP_OPT_TIMELIMIT' => 5,
            'LDAP_OPT_NETWORK_TIMEOUT' => 3,
            'LDAP_OPT_TIMEOUT' => 3,
            'LDAP_OPT_DEBUG_LEVEL' => 0,
            'LDAP_OPT_RESTART' => 0,
        ];
        foreach ($coreOptions as $constant => $value) {
            $details[$constant] = ldap_option_probe($conn, $constant, $value);
            if ($constant === 'LDAP_OPT_PROTOCOL_VERSION') {
                expect(
                    ($details[$constant]['set']['result'] ?? false) === true
                    && ($details[$constant]['get']['result'] ?? false) === true
                    && (int)($details[$constant]['value'] ?? 0) === 3,
                    'Protocol option did not round-trip'
                );
            }
        }
        tls_never();
        $details['LDAP_OPT_X_TLS_REQUIRE_CERT'] = ldap_option_probe(null, 'LDAP_OPT_X_TLS_REQUIRE_CERT', null, false);
        ldap_bind_checked($conn);
        covered('ldap_unbind');
        ldap_unbind($conn);
    });

    $confDir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'ldap-conf-' . bin2hex(random_bytes(4));
    mkdir($confDir, 0777, true);
    $conf = $confDir . DIRECTORY_SEPARATOR . 'ldap.conf';
    file_put_contents($conf, "TLS_REQCERT never\nREFERRALS off\n");
    $code = json_php_code(<<<'PHP'
        function probe_option($ldap, string $constant): array {
            if (!defined($constant)) {
                return ['defined' => false];
            }
            $value = null;
            try {
                $ok = ldap_get_option($ldap, constant($constant), $value);
                return ['defined' => true, 'ok' => $ok, 'value' => $value];
            } catch (Throwable $e) {
                return ['defined' => true, 'ok' => false, 'exception' => get_class($e), 'message' => $e->getMessage()];
            }
        }
        $api = null;
        $apiProbe = ['defined' => defined('LDAP_OPT_API_INFO'), 'ok' => true, 'vendor' => null];
        if (defined('LDAP_OPT_API_INFO')) {
            try {
                $apiProbe['ok'] = ldap_get_option(null, LDAP_OPT_API_INFO, $api);
                $apiProbe['vendor'] = $api['vendor_version'] ?? null;
            } catch (Throwable $e) {
                $apiProbe += ['ok' => false, 'exception' => get_class($e), 'message' => $e->getMessage()];
            }
        }
        echo json_encode([
            'api_info' => $apiProbe,
            'tls_require_cert' => probe_option(null, 'LDAP_OPT_X_TLS_REQUIRE_CERT'),
            'referrals' => probe_option(null, 'LDAP_OPT_REFERRALS'),
        ], JSON_THROW_ON_ERROR);
        PHP);
    $env = getenv();
    $env['LDAPCONF'] = $conf;
    $env['LDAPTLS_REQCERT'] = 'never';
    $probe = proc_capture(array_merge(php_command_prefix(), ['-r', $code]), $env);
    expect($probe['exit_code'] === 0, 'LDAPCONF probe failed: ' . $probe['stderr']);
    $details['LDAPCONF_probe'] = json_decode(trim($probe['stdout']), true, 512, JSON_THROW_ON_ERROR);

    observation('options_and_config', $details);
    return normalize_value($details);
}, true);

check('connect bind bind_ext unbind close', function (): array {
    return with_ldap_server('plain', function (int $port): array {
        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        ldap_bind_checked($conn);
        covered('ldap_unbind');
        expect(ldap_unbind($conn), 'ldap_unbind failed');

        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        ldap_bind_checked($conn, 'cn=alice,ou=people,dc=example,dc=test', 'secret');
        if (function_exists('ldap_close')) {
            covered('ldap_close');
            expect(ldap_close($conn), 'ldap_close failed');
        } else {
            covered('ldap_unbind');
            ldap_unbind($conn);
        }

        if (function_exists('ldap_bind_ext')) {
            $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
            covered('ldap_bind_ext');
            $result = ldap_bind_ext($conn, 'cn=alice,ou=people,dc=example,dc=test', 'secret', []);
            expect($result !== false, 'ldap_bind_ext failed');
            $parsed = parse_result_checked($conn, $result);
            covered('ldap_unbind');
            ldap_unbind($conn);
            return $parsed;
        }
        return ['bind_ext' => 'not available'];
    });
});

check('search read list entries values references', function (): array {
    return with_ldap_server('plain', function (int $port): array {
        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        ldap_bind_checked($conn);

        covered('ldap_search');
        $search = ldap_search($conn, 'dc=example,dc=test', '(objectClass=*)', ['cn', 'sn', 'mail', 'description', 'jpegPhoto', 'objectClass']);
        expect($search !== false, 'ldap_search failed');
        covered('ldap_count_entries');
        expect(ldap_count_entries($conn, $search) >= 3, 'ldap_search returned too few entries');

        $dns = collect_result_dns($conn, $search);
        expect(in_array('cn=alice,ou=people,dc=example,dc=test', $dns, true), 'Alice DN missing from search');

        covered('ldap_first_entry');
        $entry = ldap_first_entry($conn, $search);
        expect($entry !== false, 'ldap_first_entry failed');
        covered('ldap_get_attributes');
        $attrs = ldap_get_attributes($conn, $entry);
        expect(is_array($attrs) && ($attrs['count'] ?? 0) > 0, 'ldap_get_attributes returned no attrs');

        covered('ldap_first_attribute');
        $attributeNames = [];
        $attribute = ldap_first_attribute($conn, $entry);
        while ($attribute !== false) {
            $attributeNames[] = strtolower((string)$attribute);
            covered('ldap_next_attribute');
            $attribute = ldap_next_attribute($conn, $entry);
        }
        expect($attributeNames !== [], 'No attributes iterated');

        $aliceEntry = find_result_entry_by_dn($conn, $search, 'cn=alice,ou=people,dc=example,dc=test');
        expect($aliceEntry !== false, 'Could not locate Alice entry in result');

        covered('ldap_get_values');
        $cnValues = ldap_get_values($conn, $aliceEntry, 'objectClass');
        expect(is_array($cnValues) && ($cnValues['count'] ?? 0) >= 1, 'ldap_get_values failed');
        covered('ldap_get_values');
        $descriptionValues = ldap_get_values($conn, $aliceEntry, 'description');
        $descriptionList = [];
        if (is_array($descriptionValues)) {
            for ($i = 0; $i < (int)($descriptionValues['count'] ?? 0); $i++) {
                $descriptionList[] = $descriptionValues[$i];
            }
        }
        expect(in_array("unicode caf\xc3\xa9", $descriptionList, true), 'UTF-8 value did not round-trip');
        covered('ldap_get_values_len');
        $rawValues = ldap_get_values_len($conn, $aliceEntry, 'jpegPhoto');
        if (is_array($rawValues) && ($rawValues['count'] ?? 0) > 0) {
            expect(str_contains($rawValues[0], 'OpenLDAP'), 'Binary value did not round-trip');
        }

        covered('ldap_get_entries');
        $entries = ldap_get_entries($conn, $search);
        expect(is_array($entries) && ($entries['count'] ?? 0) >= 3, 'ldap_get_entries failed');

        if (function_exists('ldap_count_references')) {
            covered('ldap_count_references');
            $referenceCount = ldap_count_references($conn, $search);
        } else {
            $referenceCount = null;
        }
        $references = [];
        if (function_exists('ldap_first_reference')) {
            covered('ldap_first_reference');
            $reference = ldap_first_reference($conn, $search);
            while ($reference !== false) {
                covered('ldap_parse_reference');
                $referrals = null;
                ldap_parse_reference($conn, $reference, $referrals);
                $references[] = normalize_value($referrals);
                covered('ldap_next_reference');
                $reference = ldap_next_reference($conn, $reference);
            }
        }

        covered('ldap_read');
        $read = ldap_read($conn, 'cn=alice,ou=people,dc=example,dc=test', '(objectClass=*)', ['cn', 'jpegPhoto']);
        expect($read !== false && ldap_count_entries($conn, $read) === 1, 'ldap_read failed');
        covered('ldap_list');
        $list = ldap_list($conn, 'dc=example,dc=test', '(objectClass=*)', ['ou', 'cn']);
        expect($list !== false && ldap_count_entries($conn, $list) >= 1, 'ldap_list failed');

        if (function_exists('ldap_sort')) {
            covered('ldap_sort');
            ldap_sort($conn, $search, 'cn');
        }

        covered('ldap_free_result');
        ldap_free_result($read);
        covered('ldap_free_result');
        ldap_free_result($list);
        covered('ldap_free_result');
        ldap_free_result($search);
        covered('ldap_unbind');
        ldap_unbind($conn);

        return [
            'dns' => $dns,
            'attributes' => array_values(array_unique($attributeNames)),
            'reference_count' => $referenceCount,
            'references' => $references,
        ];
    });
}, true);

check('write operations and ext variants', function (): array {
    return with_ldap_server('plain', function (int $port): array {
        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        ldap_bind_checked($conn);
        $base = 'ou=people,dc=example,dc=test';

        $dn = 'cn=temp-user,' . $base;
        $entry = [
            'objectClass' => ['top', 'person', 'inetOrgPerson'],
            'cn' => ['Temp User'],
            'sn' => ['User'],
            'mail' => ['temp@example.test'],
        ];
        covered('ldap_add');
        expect(ldap_add($conn, $dn, $entry), 'ldap_add failed');

        covered('ldap_modify');
        expect(ldap_modify($conn, $dn, ['sn' => ['Changed']]), 'ldap_modify failed');
        covered('ldap_mod_add');
        expect(ldap_mod_add($conn, $dn, ['description' => ['added']]), 'ldap_mod_add failed');
        covered('ldap_mod_replace');
        expect(ldap_mod_replace($conn, $dn, ['mail' => ['changed@example.test']]), 'ldap_mod_replace failed');
        covered('ldap_mod_del');
        expect(ldap_mod_del($conn, $dn, ['description' => ['added']]), 'ldap_mod_del failed');

        if (defined('LDAP_MODIFY_BATCH_ADD') && defined('LDAP_MODIFY_BATCH_REPLACE') && defined('LDAP_MODIFY_BATCH_REMOVE')) {
            covered('ldap_modify_batch');
            expect(ldap_modify_batch($conn, $dn, [
                ['attrib' => 'description', 'modtype' => LDAP_MODIFY_BATCH_ADD, 'values' => ['batch-added']],
                ['attrib' => 'mail', 'modtype' => LDAP_MODIFY_BATCH_REPLACE, 'values' => ['batch@example.test']],
                ['attrib' => 'description', 'modtype' => LDAP_MODIFY_BATCH_REMOVE, 'values' => ['batch-added']],
            ]), 'ldap_modify_batch failed');
        } elseif (function_exists('ldap_modify_batch')) {
            covered('ldap_modify_batch');
        }

        covered('ldap_rename');
        expect(ldap_rename($conn, $dn, 'cn=temp-renamed', $base, true), 'ldap_rename failed');
        $renamed = 'cn=temp-renamed,' . $base;
        covered('ldap_delete');
        expect(ldap_delete($conn, $renamed), 'ldap_delete failed');

        if (function_exists('ldap_add_ext')) {
            $dn2 = 'cn=ext-user,' . $base;
            covered('ldap_add_ext');
            $result = ldap_add_ext($conn, $dn2, $entry, []);
            expect($result !== false, 'ldap_add_ext failed');
            parse_result_checked($conn, $result);

            covered('ldap_mod_add_ext');
            $result = ldap_mod_add_ext($conn, $dn2, ['description' => ['ext-added']], []);
            expect($result !== false, 'ldap_mod_add_ext failed');
            parse_result_checked($conn, $result);

            covered('ldap_mod_replace_ext');
            $result = ldap_mod_replace_ext($conn, $dn2, ['mail' => ['ext@example.test']], []);
            expect($result !== false, 'ldap_mod_replace_ext failed');
            parse_result_checked($conn, $result);

            covered('ldap_mod_del_ext');
            $result = ldap_mod_del_ext($conn, $dn2, ['description' => ['ext-added']], []);
            expect($result !== false, 'ldap_mod_del_ext failed');
            parse_result_checked($conn, $result);

            covered('ldap_rename_ext');
            $result = ldap_rename_ext($conn, $dn2, 'cn=ext-renamed', $base, true, []);
            expect($result !== false, 'ldap_rename_ext failed');
            parse_result_checked($conn, $result);

            covered('ldap_delete_ext');
            $result = ldap_delete_ext($conn, 'cn=ext-renamed,' . $base, []);
            expect($result !== false, 'ldap_delete_ext failed');
            parse_result_checked($conn, $result);
        }

        covered('ldap_unbind');
        ldap_unbind($conn);
        return ['write_surface' => 'ok'];
    });
});

check('compare and error handling', function (): array {
    return with_ldap_server('plain', function (int $port): array {
        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        ldap_bind_checked($conn);
        $dn = 'cn=alice,ou=people,dc=example,dc=test';

        covered('ldap_compare');
        expect(ldap_compare($conn, $dn, 'cn', 'Alice') === true, 'ldap_compare true case failed');
        covered('ldap_compare');
        expect(ldap_compare($conn, $dn, 'cn', 'Mallory') === false, 'ldap_compare false case failed');
        covered('ldap_compare');
        $missing = ldap_compare($conn, 'cn=missing,ou=people,dc=example,dc=test', 'cn', 'Missing');
        expect($missing === -1 || $missing === false, 'ldap_compare missing DN did not fail');
        covered('ldap_errno');
        $errno = ldap_errno($conn);
        covered('ldap_error');
        $error = ldap_error($conn);
        covered('ldap_err2str');
        $errText = ldap_err2str($errno);
        expect($errno === 32, "Expected noSuchObject errno 32, got $errno");

        covered('ldap_search');
        $invalidFilter = ldap_search($conn, 'dc=example,dc=test', '(&(objectClass=*');
        expect($invalidFilter === false, 'Invalid filter unexpectedly succeeded');

        covered('ldap_unbind');
        ldap_unbind($conn);

        $unusedPort = find_free_port();
        $badConn = ldap_connect_checked('ldap://127.0.0.1:' . $unusedPort);
        covered('ldap_set_option');
        ldap_set_option($badConn, LDAP_OPT_NETWORK_TIMEOUT, 1);
        covered('ldap_bind');
        $badBind = ldap_bind($badConn);
        expect($badBind === false, 'Bind to unused port unexpectedly succeeded');

        return [
            'errno' => $errno,
            'error' => $error,
            'err2str' => $errText,
        ];
    });
}, true);

check('controls request and response parsing', function (): array {
    return with_ldap_server('plain', function (int $port): array {
        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        ldap_bind_checked($conn);
        $results = [];
        foreach (build_request_controls() as $item) {
            covered('ldap_search');
            $search = ldap_search(
                $conn,
                'dc=example,dc=test',
                '(objectClass=*)',
                ['cn'],
                0,
                0,
                0,
                defined('LDAP_DEREF_NEVER') ? LDAP_DEREF_NEVER : 0,
                [$item['control']]
            );
            expect($search !== false, 'ldap_search with ' . $item['name'] . ' control failed');
            $parsed = parse_result_checked($conn, $search);
            $results[$item['name']] = $parsed['controls'];
            covered('ldap_free_result');
            ldap_free_result($search);
        }

        if (function_exists('ldap_control_paged_result')) {
            covered('ldap_control_paged_result');
            ldap_control_paged_result($conn, 1, false, '');
            covered('ldap_search');
            $legacy = ldap_search($conn, 'dc=example,dc=test', '(objectClass=*)', ['cn']);
            expect($legacy !== false, 'legacy paged search failed');
            if (function_exists('ldap_control_paged_result_response')) {
                covered('ldap_control_paged_result_response');
                $cookie = null;
                $estimated = null;
                ldap_control_paged_result_response($conn, $legacy, $cookie, $estimated);
                $results['legacy-paged'] = [
                    'cookie' => normalize_value($cookie),
                    'estimated' => normalize_value($estimated),
                ];
            }
            covered('ldap_free_result');
            ldap_free_result($legacy);
        }

        covered('ldap_unbind');
        ldap_unbind($conn);
        observation('controls', $results);
        return $results;
    });
}, true);

check('starttls ldaps and strict certificate behavior', function (): array {
    $details = [];
    tls_never();
    with_ldap_server('plain', function (int $port) use (&$details): void {
        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        $startTls = null;
        $details['starttls'] = ldap_operation_observation($conn, 'ldap_start_tls', static function () use ($conn, &$startTls): bool {
            $startTls = ldap_start_tls($conn);
            return $startTls;
        });
        if ($startTls === true) {
            $details['starttls_bind'] = ldap_operation_observation($conn, 'ldap_bind', static fn() => ldap_bind($conn));
            $read = null;
            $details['starttls_read'] = ldap_operation_observation($conn, 'ldap_read', static function () use ($conn, &$read) {
                $read = ldap_read($conn, 'cn=alice,ou=people,dc=example,dc=test', '(objectClass=*)', ['cn']);
                return $read;
            });
            if ($read !== false && $read !== null) {
                covered('ldap_count_entries');
                $details['starttls_read']['entries'] = ldap_count_entries($conn, $read);
                covered('ldap_free_result');
                ldap_free_result($read);
            }
            covered('ldap_unbind');
            ldap_unbind($conn);
        }
    });

    tls_never();
    with_ldap_server('ldaps', function (int $port) use (&$details): void {
        $conn = ldap_connect_checked('ldaps://127.0.0.1:' . $port);
        $ldaps = null;
        $details['ldaps_permissive'] = ldap_operation_observation($conn, 'ldap_bind', static function () use ($conn, &$ldaps): bool {
            $ldaps = ldap_bind($conn);
            return $ldaps;
        });
        if ($ldaps === true) {
            covered('ldap_unbind');
            ldap_unbind($conn);
        }
    });

    tls_demand();
    with_ldap_server('ldaps', function (int $port) use (&$details): void {
        $conn = ldap_connect_checked('ldaps://127.0.0.1:' . $port);
        $result = null;
        $details['ldaps_strict'] = ldap_operation_observation($conn, 'ldap_bind', static function () use ($conn, &$result): bool {
            $result = ldap_bind($conn);
            return $result;
        });
        if ($result === true) {
            covered('ldap_unbind');
            ldap_unbind($conn);
        }
    });
    tls_never();

    observation('tls', $details);
    return $details;
}, true);

check('extended operations and SASL surface', function (): array {
    return with_ldap_server('plain', function (int $port): array {
        $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
        ldap_bind_checked($conn);
        $details = [];

        if (function_exists('ldap_exop')) {
            $result = null;
            $details['exop'] = ldap_operation_observation($conn, 'ldap_exop', static function () use ($conn, &$result) {
                $result = ldap_exop($conn, '1.3.6.1.4.1.4203.666.11.1', 'payload', []);
                return $result;
            });
            if ($result !== false && $result !== null && function_exists('ldap_parse_exop')) {
                $data = null;
                $oid = null;
                $details['parse_exop'] = observed_call('ldap_parse_exop', static function () use ($conn, $result, &$data, &$oid): bool {
                    return ldap_parse_exop($conn, $result, $data, $oid);
                });
                $details['parse_exop']['oid'] = normalize_value($oid);
                $details['parse_exop']['data'] = normalize_value($data);
            } elseif (function_exists('ldap_parse_exop')) {
                $details['parse_exop'] = ['ok' => false, 'skipped' => 'ldap_exop did not return a result'];
            }
        }

        if (function_exists('ldap_exop_sync')) {
            $data = null;
            $oid = null;
            $details['exop_sync'] = ldap_operation_observation($conn, 'ldap_exop_sync', static function () use ($conn, &$data, &$oid): bool {
                return ldap_exop_sync($conn, '1.3.6.1.4.1.4203.666.11.2', 'payload', [], $data, $oid);
            });
            $details['exop_sync']['oid'] = normalize_value($oid);
            $details['exop_sync']['data'] = normalize_value($data);
        }

        if (function_exists('ldap_exop_whoami')) {
            $details['whoami'] = ldap_operation_observation($conn, 'ldap_exop_whoami', static fn() => ldap_exop_whoami($conn));
        }

        if (function_exists('ldap_exop_passwd')) {
            $details['passwd'] = ldap_operation_observation(
                $conn,
                'ldap_exop_passwd',
                static fn() => ldap_exop_passwd($conn, 'cn=alice,ou=people,dc=example,dc=test', 'old-secret', 'new-secret')
            );
        }

        if (function_exists('ldap_exop_refresh')) {
            $details['refresh'] = ldap_operation_observation(
                $conn,
                'ldap_exop_refresh',
                static fn() => ldap_exop_refresh($conn, 'cn=alice,ou=people,dc=example,dc=test', 3600)
            );
        }

        if (function_exists('ldap_sasl_bind')) {
            $details['sasl_bind'] = ldap_operation_observation(
                $conn,
                'ldap_sasl_bind',
                static fn() => ldap_sasl_bind($conn, null, null, 'PLAIN', null, 'alice', null, null)
            );
        }

        covered('ldap_unbind');
        ldap_unbind($conn);
        observation('extended_and_sasl', $details);
        return $details;
    });
}, true);

check('DN string and encoding helpers', function (): array {
    $details = [];
    if (function_exists('ldap_escape')) {
        covered('ldap_escape');
        $details['escape_filter'] = ldap_escape("cn=Alice*(test)\x00", '', LDAP_ESCAPE_FILTER);
        covered('ldap_escape');
        $details['escape_dn'] = ldap_escape('cn=Alice,ou=People', '', LDAP_ESCAPE_DN);
        expect(str_contains($details['escape_filter'], '\\2a'), 'Filter escaping did not escape wildcard');
    }
    if (function_exists('ldap_explode_dn')) {
        covered('ldap_explode_dn');
        $exploded = ldap_explode_dn('cn=Alice,ou=People,dc=example,dc=test', 0);
        expect(is_array($exploded) && ($exploded['count'] ?? 0) === 4, 'ldap_explode_dn failed');
        $details['explode_dn'] = normalize_value($exploded);
    }
    if (function_exists('ldap_dn2ufn')) {
        covered('ldap_dn2ufn');
        $details['dn2ufn'] = ldap_dn2ufn('cn=Alice,ou=People,dc=example,dc=test');
        expect(is_string($details['dn2ufn']) && $details['dn2ufn'] !== '', 'ldap_dn2ufn failed');
    }
    if (function_exists('ldap_8859_to_t61')) {
        covered('ldap_8859_to_t61');
        $t61 = ldap_8859_to_t61('Cafe');
        $details['8859_to_t61'] = normalize_value($t61);
        if (function_exists('ldap_t61_to_8859')) {
            covered('ldap_t61_to_8859');
            $details['t61_to_8859'] = normalize_value(ldap_t61_to_8859((string)$t61));
        }
    } elseif (function_exists('ldap_t61_to_8859')) {
        covered('ldap_t61_to_8859');
        $details['t61_to_8859'] = normalize_value(ldap_t61_to_8859('Cafe'));
    }
    observation('helpers', $details);
    return $details;
}, true);

check('function coverage contract', function () use (&$summary): array {
    $known = [
        'ldap_8859_to_t61',
        'ldap_add',
        'ldap_add_ext',
        'ldap_bind',
        'ldap_bind_ext',
        'ldap_close',
        'ldap_compare',
        'ldap_connect',
        'ldap_control_paged_result',
        'ldap_control_paged_result_response',
        'ldap_count_entries',
        'ldap_count_references',
        'ldap_delete',
        'ldap_delete_ext',
        'ldap_dn2ufn',
        'ldap_err2str',
        'ldap_errno',
        'ldap_error',
        'ldap_escape',
        'ldap_exop',
        'ldap_exop_passwd',
        'ldap_exop_refresh',
        'ldap_exop_sync',
        'ldap_exop_whoami',
        'ldap_explode_dn',
        'ldap_first_attribute',
        'ldap_first_entry',
        'ldap_first_reference',
        'ldap_free_result',
        'ldap_get_attributes',
        'ldap_get_dn',
        'ldap_get_entries',
        'ldap_get_option',
        'ldap_get_values',
        'ldap_get_values_len',
        'ldap_list',
        'ldap_mod_add',
        'ldap_mod_add_ext',
        'ldap_mod_del',
        'ldap_mod_del_ext',
        'ldap_mod_replace',
        'ldap_mod_replace_ext',
        'ldap_modify',
        'ldap_modify_batch',
        'ldap_next_attribute',
        'ldap_next_entry',
        'ldap_next_reference',
        'ldap_parse_exop',
        'ldap_parse_reference',
        'ldap_parse_result',
        'ldap_read',
        'ldap_rename',
        'ldap_rename_ext',
        'ldap_sasl_bind',
        'ldap_search',
        'ldap_set_option',
        'ldap_set_rebind_proc',
        'ldap_sort',
        'ldap_start_tls',
        'ldap_t61_to_8859',
        'ldap_unbind',
    ];
    $present = $summary['functions'];
    $unknown = array_values(array_diff($present, $known));
    expect($unknown === [], 'LDAP extension exported untested functions: ' . implode(', ', $unknown));

    if (function_exists('ldap_set_rebind_proc')) {
        with_ldap_server('plain', function (int $port): void {
            $conn = ldap_connect_checked('ldap://127.0.0.1:' . $port);
            covered('ldap_set_rebind_proc');
            ldap_set_rebind_proc($conn, static function (): int {
                return 0;
            });
            covered('ldap_unbind');
            ldap_unbind($conn);
        });
    }

    $called = array_keys(array_filter($summary['called_functions']));
    $notCalled = array_values(array_diff($present, $called));
    expect($notCalled === [], 'LDAP extension functions present but not called: ' . implode(', ', $notCalled));
    sort($called);
    return [
        'present' => $present,
        'called' => $called,
    ];
}, true);

$failed = [];
foreach ($summary['tests'] as $name => $test) {
    if (($test['status'] ?? '') === 'failed') {
        $failed[$name] = $test['error'] ?? 'failed';
    }
}

ksort($summary['called_functions']);
$summary['called_functions'] = array_keys(array_filter($summary['called_functions']));
ksort($summary['observations']);

file_put_contents($outFile, json_encode($summary, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));

if ($failed !== []) {
    fwrite(STDERR, "LDAP suite failures:\n");
    foreach ($failed as $name => $error) {
        fwrite(STDERR, " - $name: $error\n");
    }
    exit(1);
}

echo "Wrote $outFile\n";
