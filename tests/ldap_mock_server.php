<?php

declare(strict_types=1);

$args = getopt('', [
    'mode:',
    'port:',
    'ready:',
    'cert:',
    'key:',
    'log:',
    'max-connections::',
]);

$mode = $args['mode'] ?? 'plain';
$port = (int)($args['port'] ?? 0);
$readyFile = $args['ready'] ?? '';
$certFile = $args['cert'] ?? '';
$keyFile = $args['key'] ?? '';
$logFile = $args['log'] ?? '';
$maxConnections = (int)($args['max-connections'] ?? 30);

if ($port <= 0 || $readyFile === '') {
    fwrite(STDERR, "Missing --port or --ready\n");
    exit(2);
}

function log_line(string $message): void
{
    global $logFile;
    if ($logFile !== '') {
        file_put_contents($logFile, '[' . date('H:i:s') . '] ' . $message . PHP_EOL, FILE_APPEND);
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

function ber_set(string $payload): string
{
    return ber_tag(0x31, $payload);
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

function ber_bool(bool $value): string
{
    return ber_tag(0x01, $value ? "\xff" : "\x00");
}

function ber_octet(string $value): string
{
    return ber_tag(0x04, $value);
}

function ber_app(int $number, string $payload, bool $constructed = true): string
{
    return ber_tag(0x40 | ($constructed ? 0x20 : 0x00) | $number, $payload);
}

function ber_ctx(int $number, string $payload, bool $constructed = false): string
{
    return ber_tag(0x80 | ($constructed ? 0x20 : 0x00) | $number, $payload);
}

function ber_decode_length(string $data, int &$pos): int
{
    if ($pos >= strlen($data)) {
        throw new RuntimeException('Unexpected end while decoding length');
    }
    $first = ord($data[$pos++]);
    if (($first & 0x80) === 0) {
        return $first;
    }
    $count = $first & 0x7f;
    if ($count === 0 || $count > 4 || $pos + $count > strlen($data)) {
        throw new RuntimeException('Unsupported BER length');
    }
    $length = 0;
    for ($i = 0; $i < $count; $i++) {
        $length = ($length << 8) | ord($data[$pos++]);
    }
    return $length;
}

function ber_read_element(string $data, int &$pos): array
{
    if ($pos >= strlen($data)) {
        throw new RuntimeException('Unexpected end while decoding element');
    }
    $tag = ord($data[$pos++]);
    $length = ber_decode_length($data, $pos);
    if ($pos + $length > strlen($data)) {
        throw new RuntimeException('Element length exceeds frame length');
    }
    $payload = substr($data, $pos, $length);
    $pos += $length;
    return [$tag, $payload];
}

function ber_decode_int(string $payload): int
{
    $value = 0;
    for ($i = 0, $length = strlen($payload); $i < $length; $i++) {
        $value = ($value << 8) | ord($payload[$i]);
    }
    return $value;
}

function read_exact($stream, int $length): ?string
{
    $data = '';
    while (strlen($data) < $length && !feof($stream)) {
        $chunk = fread($stream, $length - strlen($data));
        if ($chunk === false || $chunk === '') {
            $meta = stream_get_meta_data($stream);
            if (!empty($meta['timed_out'])) {
                return null;
            }
            usleep(1000);
            continue;
        }
        $data .= $chunk;
    }
    return strlen($data) === $length ? $data : null;
}

function read_ldap_frame($stream): ?array
{
    $tagByte = read_exact($stream, 1);
    if ($tagByte === null) {
        return null;
    }
    $lengthByte = read_exact($stream, 1);
    if ($lengthByte === null) {
        return null;
    }
    $first = ord($lengthByte);
    if (($first & 0x80) === 0) {
        $length = $first;
    } else {
        $count = $first & 0x7f;
        $lengthBytes = read_exact($stream, $count);
        if ($lengthBytes === null) {
            return null;
        }
        $length = 0;
        for ($i = 0; $i < $count; $i++) {
            $length = ($length << 8) | ord($lengthBytes[$i]);
        }
    }
    $payload = read_exact($stream, $length);
    if ($payload === null) {
        return null;
    }
    return [ord($tagByte), $payload];
}

function normalize_dn(string $dn): string
{
    return strtolower(trim($dn));
}

function parent_dn(string $dn): string
{
    $parts = explode(',', $dn, 2);
    return $parts[1] ?? '';
}

function attr_entry(string $dn, array $attrs): array
{
    $normalized = [];
    foreach ($attrs as $name => $values) {
        $valueList = is_array($values) ? array_values($values) : [$values];
        $normalized[strtolower((string)$name)] = [
            'name' => (string)$name,
            'values' => array_map(static fn($value): string => (string)$value, $valueList),
        ];
    }
    return [
        'dn' => $dn,
        'attrs' => $normalized,
    ];
}

$entries = [
    normalize_dn('dc=example,dc=test') => attr_entry('dc=example,dc=test', [
        'objectClass' => ['top', 'domain'],
        'dc' => 'example',
        'description' => 'OpenLDAP PHP regression root',
    ]),
    normalize_dn('ou=people,dc=example,dc=test') => attr_entry('ou=people,dc=example,dc=test', [
        'objectClass' => ['top', 'organizationalUnit'],
        'ou' => 'people',
        'description' => 'People container',
    ]),
    normalize_dn('cn=alice,ou=people,dc=example,dc=test') => attr_entry('cn=alice,ou=people,dc=example,dc=test', [
        'objectClass' => ['top', 'person', 'inetOrgPerson'],
        'cn' => 'Alice',
        'sn' => 'Liddell',
        'mail' => 'alice@example.test',
        'description' => ['plain text', "unicode caf\xc3\xa9"],
        'jpegPhoto' => "\x00\x01OpenLDAP\xffBinary",
    ]),
    normalize_dn('cn=bob,ou=people,dc=example,dc=test') => attr_entry('cn=bob,ou=people,dc=example,dc=test', [
        'objectClass' => ['top', 'person', 'inetOrgPerson'],
        'cn' => 'Bob',
        'sn' => 'Builder',
        'mail' => 'bob@example.test',
        'description' => 'second user',
    ]),
];

function ldap_message(int $messageId, string $protocolOp, string $controls = ''): string
{
    return ber_seq(ber_int($messageId) . $protocolOp . $controls);
}

function ldap_result_op(int $app, int $code = 0, string $matched = '', string $diagnostic = ''): string
{
    return ber_app($app, ber_enum($code) . ber_octet($matched) . ber_octet($diagnostic));
}

function ldap_control(string $oid, ?string $value = null, ?bool $critical = null): string
{
    $payload = ber_octet($oid);
    if ($critical !== null) {
        $payload .= ber_bool($critical);
    }
    if ($value !== null) {
        $payload .= ber_octet($value);
    }
    return ber_seq($payload);
}

function ldap_response_controls(): string
{
    $paged = ber_seq(ber_int(0) . ber_octet(''));
    $sort = ber_seq(ber_enum(0));
    $vlv = ber_seq(ber_int(1) . ber_int(2) . ber_enum(0) . ber_octet('ctx'));
    $controls = ldap_control('1.2.840.113556.1.4.319', $paged)
        . ldap_control('1.2.840.113556.1.4.474', $sort)
        . ldap_control('2.16.840.1.113730.3.4.10', $vlv)
        . ldap_control('1.3.6.1.4.1.4203.666.5.999', 'mock-control');
    return ber_ctx(0, $controls, true);
}

function search_entry_op(array $entry, array $requestedAttrs): string
{
    $attrs = '';
    foreach ($entry['attrs'] as $lower => $attr) {
        if ($requestedAttrs !== [] && !in_array($lower, $requestedAttrs, true) && !in_array('*', $requestedAttrs, true)) {
            continue;
        }
        $values = '';
        foreach ($attr['values'] as $value) {
            $values .= ber_octet($value);
        }
        $attrs .= ber_seq(ber_octet($attr['name']) . ber_set($values));
    }
    return ber_app(4, ber_octet($entry['dn']) . ber_seq($attrs));
}

function search_reference_op(): string
{
    return ber_app(19, ber_octet('ldap://127.0.0.1:389/dc=ref,dc=example,dc=test??sub?(objectClass=*)'));
}

function parse_attribute_selection(string $payload): array
{
    $attrs = [];
    $pos = 0;
    while ($pos < strlen($payload)) {
        [$tag, $value] = ber_read_element($payload, $pos);
        if ($tag === 0x04 && $value !== '1.1') {
            $attrs[] = strtolower($value);
        }
    }
    return $attrs;
}

function parse_partial_attributes(string $payload): array
{
    $attrs = [];
    $pos = 0;
    while ($pos < strlen($payload)) {
        [$tag, $value] = ber_read_element($payload, $pos);
        if ($tag !== 0x30) {
            continue;
        }
        $attrPos = 0;
        [, $name] = ber_read_element($value, $attrPos);
        [, $setPayload] = ber_read_element($value, $attrPos);
        $values = [];
        $setPos = 0;
        while ($setPos < strlen($setPayload)) {
            [, $attrValue] = ber_read_element($setPayload, $setPos);
            $values[] = $attrValue;
        }
        $attrs[$name] = $values;
    }
    return $attrs;
}

function parse_search_request(string $payload): array
{
    $pos = 0;
    [, $base] = ber_read_element($payload, $pos);
    [, $scopePayload] = ber_read_element($payload, $pos);
    $scope = ber_decode_int($scopePayload);
    ber_read_element($payload, $pos);
    ber_read_element($payload, $pos);
    ber_read_element($payload, $pos);
    ber_read_element($payload, $pos);
    ber_read_element($payload, $pos);
    [, $attrsPayload] = ber_read_element($payload, $pos);
    return [$base, $scope, parse_attribute_selection($attrsPayload)];
}

function entry_matches_scope(string $entryDn, string $base, int $scope): bool
{
    $entry = normalize_dn($entryDn);
    $base = normalize_dn($base);
    if ($scope === 0) {
        return $entry === $base;
    }
    if ($scope === 1) {
        return normalize_dn(parent_dn($entryDn)) === $base;
    }
    return $entry === $base || str_ends_with($entry, ',' . $base);
}

function handle_search(int $messageId, string $payload): array
{
    global $entries;
    [$base, $scope, $attrs] = parse_search_request($payload);
    $frames = [];
    foreach ($entries as $entry) {
        if (entry_matches_scope($entry['dn'], $base, $scope)) {
            $frames[] = ldap_message($messageId, search_entry_op($entry, $attrs));
        }
    }
    if ($scope !== 0) {
        $frames[] = ldap_message($messageId, search_reference_op());
    }
    $frames[] = ldap_message($messageId, ldap_result_op(5), ldap_response_controls());
    return $frames;
}

function handle_add(int $messageId, string $payload): array
{
    global $entries;
    $pos = 0;
    [, $dn] = ber_read_element($payload, $pos);
    [, $attrsPayload] = ber_read_element($payload, $pos);
    $attrs = parse_partial_attributes($attrsPayload);
    $entries[normalize_dn($dn)] = attr_entry($dn, $attrs);
    return [ldap_message($messageId, ldap_result_op(9))];
}

function handle_modify(int $messageId, string $payload): array
{
    global $entries;
    $pos = 0;
    [, $dn] = ber_read_element($payload, $pos);
    [, $changesPayload] = ber_read_element($payload, $pos);
    $key = normalize_dn($dn);
    if (!isset($entries[$key])) {
        return [ldap_message($messageId, ldap_result_op(7, 32, '', 'noSuchObject'))];
    }
    $changePos = 0;
    while ($changePos < strlen($changesPayload)) {
        [, $changePayload] = ber_read_element($changesPayload, $changePos);
        $itemPos = 0;
        [, $opPayload] = ber_read_element($changePayload, $itemPos);
        $operation = ber_decode_int($opPayload);
        [, $modPayload] = ber_read_element($changePayload, $itemPos);
        $partial = parse_partial_attributes(ber_seq($modPayload));
        foreach ($partial as $name => $values) {
            $lower = strtolower($name);
            if ($operation === 0) {
                $existing = $entries[$key]['attrs'][$lower]['values'] ?? [];
                $entries[$key]['attrs'][$lower] = [
                    'name' => $name,
                    'values' => array_values(array_unique(array_merge($existing, $values))),
                ];
            } elseif ($operation === 1) {
                if ($values === []) {
                    unset($entries[$key]['attrs'][$lower]);
                } elseif (isset($entries[$key]['attrs'][$lower])) {
                    $entries[$key]['attrs'][$lower]['values'] = array_values(array_diff($entries[$key]['attrs'][$lower]['values'], $values));
                }
            } elseif ($operation === 2 || $operation === 3) {
                $entries[$key]['attrs'][$lower] = [
                    'name' => $name,
                    'values' => $values,
                ];
            }
        }
    }
    return [ldap_message($messageId, ldap_result_op(7))];
}

function handle_delete(int $messageId, string $dn): array
{
    global $entries;
    unset($entries[normalize_dn($dn)]);
    return [ldap_message($messageId, ldap_result_op(11))];
}

function handle_rename(int $messageId, string $payload): array
{
    global $entries;
    $pos = 0;
    [, $dn] = ber_read_element($payload, $pos);
    [, $newRdn] = ber_read_element($payload, $pos);
    ber_read_element($payload, $pos);
    $parent = parent_dn($dn);
    if ($pos < strlen($payload)) {
        [$tag, $superior] = ber_read_element($payload, $pos);
        if ($tag === 0x80) {
            $parent = $superior;
        }
    }
    $key = normalize_dn($dn);
    if (!isset($entries[$key])) {
        return [ldap_message($messageId, ldap_result_op(13, 32, '', 'noSuchObject'))];
    }
    $newDn = $newRdn . ($parent !== '' ? ',' . $parent : '');
    $entry = $entries[$key];
    unset($entries[$key]);
    $entry['dn'] = $newDn;
    $entries[normalize_dn($newDn)] = $entry;
    return [ldap_message($messageId, ldap_result_op(13))];
}

function handle_compare(int $messageId, string $payload): array
{
    global $entries;
    $pos = 0;
    [, $dn] = ber_read_element($payload, $pos);
    [, $avaPayload] = ber_read_element($payload, $pos);
    $avaPos = 0;
    [, $attr] = ber_read_element($avaPayload, $avaPos);
    [, $value] = ber_read_element($avaPayload, $avaPos);
    $entry = $entries[normalize_dn($dn)] ?? null;
    if ($entry === null) {
        return [ldap_message($messageId, ldap_result_op(15, 32, '', 'noSuchObject'))];
    }
    $values = $entry['attrs'][strtolower($attr)]['values'] ?? [];
    return [ldap_message($messageId, ldap_result_op(15, in_array($value, $values, true) ? 6 : 5))];
}

function parse_extended_request(string $payload): array
{
    $pos = 0;
    $oid = '';
    $value = '';
    while ($pos < strlen($payload)) {
        [$tag, $part] = ber_read_element($payload, $pos);
        if ($tag === 0x80) {
            $oid = $part;
        } elseif ($tag === 0x81) {
            $value = $part;
        }
    }
    return [$oid, $value];
}

function extended_response_op(string $oid, string $value = ''): string
{
    $payload = ber_enum(0) . ber_octet('') . ber_octet('');
    if ($oid !== '') {
        $payload .= ber_ctx(10, $oid);
    }
    if ($value !== '') {
        $payload .= ber_ctx(11, $value);
    }
    return ber_app(24, $payload);
}

function handle_extended(int $messageId, string $payload): array
{
    [$oid] = parse_extended_request($payload);
    $startTlsOid = '1.3.6.1.4.1.1466.20037';
    if ($oid === $startTlsOid) {
        return [
            'frames' => [ldap_message($messageId, extended_response_op($oid))],
            'start_tls' => true,
        ];
    }
    if ($oid === '1.3.6.1.4.1.4203.1.11.3') {
        return ['frames' => [ldap_message($messageId, extended_response_op($oid, 'dn:cn=alice,ou=people,dc=example,dc=test'))]];
    }
    if ($oid === '1.3.6.1.4.1.4203.1.11.1') {
        return ['frames' => [ldap_message($messageId, extended_response_op($oid, ber_seq(ber_ctx(0, 'generated-secret'))))]];
    }
    if ($oid === '1.3.6.1.4.1.1466.101.119.1') {
        return ['frames' => [ldap_message($messageId, extended_response_op($oid, ber_seq(ber_int(3600))))]];
    }
    return ['frames' => [ldap_message($messageId, extended_response_op($oid, 'mock-exop-response'))]];
}

function handle_message(string $messagePayload): array
{
    $pos = 0;
    [$idTag, $idPayload] = ber_read_element($messagePayload, $pos);
    if ($idTag !== 0x02) {
        throw new RuntimeException('LDAP message without message id');
    }
    $messageId = ber_decode_int($idPayload);
    [$opTag, $opPayload] = ber_read_element($messagePayload, $pos);
    log_line(sprintf('message id=%d op=0x%02x', $messageId, $opTag));

    switch ($opTag) {
        case 0x60:
            return ['frames' => [ldap_message($messageId, ldap_result_op(1))]];
        case 0x63:
            return ['frames' => handle_search($messageId, $opPayload)];
        case 0x68:
            return ['frames' => handle_add($messageId, $opPayload)];
        case 0x66:
            return ['frames' => handle_modify($messageId, $opPayload)];
        case 0x4a:
            return ['frames' => handle_delete($messageId, $opPayload)];
        case 0x6c:
            return ['frames' => handle_rename($messageId, $opPayload)];
        case 0x6e:
            return ['frames' => handle_compare($messageId, $opPayload)];
        case 0x77:
            return handle_extended($messageId, $opPayload);
        case 0x42:
            return ['frames' => [], 'unbind' => true];
        default:
            return ['frames' => [ldap_message($messageId, ldap_result_op(1, 2, '', 'unsupported operation'))]];
    }
}

function ssl_context_options(string $certFile, string $keyFile): array
{
    return [
        'ssl' => [
            'local_cert' => $certFile,
            'local_pk' => $keyFile,
            'allow_self_signed' => true,
            'verify_peer' => false,
            'verify_peer_name' => false,
            'crypto_method' => STREAM_CRYPTO_METHOD_TLS_SERVER,
        ],
    ];
}

$context = stream_context_create(ssl_context_options($certFile, $keyFile));
$server = @stream_socket_server(
    'tcp://127.0.0.1:' . $port,
    $errno,
    $error,
    STREAM_SERVER_BIND | STREAM_SERVER_LISTEN,
    $context
);

if (!$server) {
    file_put_contents($readyFile, 'error:' . $error);
    log_line("server failed: $error");
    exit(1);
}

stream_set_timeout($server, 20);
file_put_contents($readyFile, 'ready');
log_line("server ready on port $port mode=$mode");

$connections = 0;
while ($connections < $maxConnections) {
    $client = @stream_socket_accept($server, 20);
    if (!$client) {
        break;
    }
    $connections++;
    stream_set_timeout($client, 10);
    if ($mode === 'ldaps') {
        $ok = @stream_socket_enable_crypto($client, true, STREAM_CRYPTO_METHOD_TLS_SERVER);
        if ($ok !== true) {
            log_line('ldaps handshake failed');
            fclose($client);
            continue;
        }
    }

    while (!feof($client)) {
        $frame = read_ldap_frame($client);
        if ($frame === null) {
            break;
        }
        [$tag, $payload] = $frame;
        if ($tag !== 0x30) {
            log_line(sprintf('unexpected top-level tag 0x%02x', $tag));
            break;
        }
        try {
            $response = handle_message($payload);
            foreach ($response['frames'] as $responseFrame) {
                fwrite($client, $responseFrame);
            }
            if (!empty($response['start_tls'])) {
                $ok = @stream_socket_enable_crypto($client, true, STREAM_CRYPTO_METHOD_TLS_SERVER);
                if ($ok !== true) {
                    log_line('starttls handshake failed');
                    break;
                }
            }
            if (!empty($response['unbind'])) {
                break;
            }
        } catch (Throwable $e) {
            log_line('handler error: ' . $e->getMessage());
            break;
        }
    }
    fclose($client);
}

log_line('server exit');
