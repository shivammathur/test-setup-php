<?php
declare(strict_types=1);

function parse_options(array $argv): array
{
    $options = [];
    for ($i = 1; $i < count($argv); $i++) {
        if (!str_starts_with($argv[$i], '--')) {
            continue;
        }
        $key = substr($argv[$i], 2);
        $value = true;
        if (isset($argv[$i + 1]) && !str_starts_with($argv[$i + 1], '--')) {
            $value = $argv[++$i];
        }
        $options[$key] = $value;
    }
    return $options;
}

function server_fail(string $message): never
{
    throw new RuntimeException($message);
}

function read_exact($stream, int $length): string
{
    $data = '';
    while (strlen($data) < $length) {
        $chunk = fread($stream, $length - strlen($data));
        if ($chunk === false) {
            server_fail('Unable to read from client socket');
        }
        if ($chunk === '') {
            $meta = stream_get_meta_data($stream);
            if (($meta['timed_out'] ?? false) || feof($stream)) {
                server_fail('Timed out or reached EOF while reading from client socket');
            }
            usleep(10000);
            continue;
        }
        $data .= $chunk;
    }
    return $data;
}

function read_ber_length_from_stream($stream): array
{
    $first = ord(read_exact($stream, 1));
    if (($first & 0x80) === 0) {
        return [chr($first), $first];
    }

    $octets = $first & 0x7f;
    if ($octets === 0 || $octets > 4) {
        server_fail("Unsupported BER length octet count: {$octets}");
    }
    $bytes = read_exact($stream, $octets);
    $length = 0;
    for ($i = 0; $i < strlen($bytes); $i++) {
        $length = ($length << 8) | ord($bytes[$i]);
    }
    return [chr($first) . $bytes, $length];
}

function read_ldap_packet($stream, bool $required = true): ?string
{
    $tag = fread($stream, 1);
    if ($tag === false) {
        server_fail('Unable to read LDAP packet tag');
    }
    if ($tag === '') {
        if ($required) {
            server_fail('No LDAP packet was received');
        }
        return null;
    }
    if (ord($tag) !== 0x30) {
        server_fail(sprintf('Expected LDAPMessage sequence tag 0x30, got 0x%02x', ord($tag)));
    }

    [$lengthBytes, $length] = read_ber_length_from_stream($stream);
    return $tag . $lengthBytes . read_exact($stream, $length);
}

function read_length(string $data, int &$offset): int
{
    if ($offset >= strlen($data)) {
        server_fail('Unexpected end of BER data while reading length');
    }
    $first = ord($data[$offset++]);
    if (($first & 0x80) === 0) {
        return $first;
    }
    $octets = $first & 0x7f;
    if ($octets === 0 || $octets > 4 || $offset + $octets > strlen($data)) {
        server_fail('Invalid BER long-form length');
    }
    $length = 0;
    for ($i = 0; $i < $octets; $i++) {
        $length = ($length << 8) | ord($data[$offset++]);
    }
    return $length;
}

function read_tlv(string $data, int &$offset): array
{
    if ($offset >= strlen($data)) {
        server_fail('Unexpected end of BER data while reading tag');
    }
    $tag = ord($data[$offset++]);
    $length = read_length($data, $offset);
    if ($offset + $length > strlen($data)) {
        server_fail('BER value extends past the packet boundary');
    }
    $value = substr($data, $offset, $length);
    $offset += $length;
    return [$tag, $value];
}

function decode_integer(string $value): int
{
    if ($value === '') {
        server_fail('BER integer has no bytes');
    }
    $integer = 0;
    for ($i = 0; $i < strlen($value); $i++) {
        $integer = ($integer << 8) | ord($value[$i]);
    }
    return $integer;
}

function parse_bind_request(string $packet): array
{
    $offset = 0;
    [$tag, $message] = read_tlv($packet, $offset);
    if ($tag !== 0x30 || $offset !== strlen($packet)) {
        server_fail('Invalid LDAPMessage wrapper');
    }

    $messageOffset = 0;
    [$tag, $messageIdValue] = read_tlv($message, $messageOffset);
    if ($tag !== 0x02) {
        server_fail(sprintf('Expected messageID integer tag, got 0x%02x', $tag));
    }
    $messageId = decode_integer($messageIdValue);

    [$tag, $bind] = read_tlv($message, $messageOffset);
    if ($tag !== 0x60) {
        server_fail(sprintf('Expected BindRequest tag 0x60, got 0x%02x', $tag));
    }

    $bindOffset = 0;
    [$tag, $versionValue] = read_tlv($bind, $bindOffset);
    if ($tag !== 0x02) {
        server_fail('BindRequest version is missing');
    }
    $version = decode_integer($versionValue);

    [$tag, $name] = read_tlv($bind, $bindOffset);
    if ($tag !== 0x04) {
        server_fail('BindRequest name is missing');
    }

    [$tag, $sasl] = read_tlv($bind, $bindOffset);
    if ($tag !== 0xa3) {
        server_fail(sprintf('Expected SASL authentication tag 0xa3, got 0x%02x', $tag));
    }

    $saslOffset = 0;
    [$tag, $mechanism] = read_tlv($sasl, $saslOffset);
    if ($tag !== 0x04) {
        server_fail('SASL mechanism is missing');
    }
    $credentials = '';
    if ($saslOffset < strlen($sasl)) {
        [$tag, $credentials] = read_tlv($sasl, $saslOffset);
        if ($tag !== 0x04) {
            server_fail('SASL credentials must be an octet string');
        }
    }

    return [
        'message_id' => $messageId,
        'version' => $version,
        'name' => $name,
        'mechanism' => $mechanism,
        'credentials' => $credentials,
        'plain_parts' => explode("\0", $credentials),
    ];
}

function parse_unbind_request(string $packet): bool
{
    $offset = 0;
    [$tag, $message] = read_tlv($packet, $offset);
    if ($tag !== 0x30) {
        return false;
    }
    $messageOffset = 0;
    [$tag] = read_tlv($message, $messageOffset);
    if ($tag !== 0x02 || $messageOffset >= strlen($message)) {
        return false;
    }
    [$tag, $value] = read_tlv($message, $messageOffset);
    return $tag === 0x42 && $value === '';
}

function encode_length(int $length): string
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

function tlv(int $tag, string $value): string
{
    return chr($tag) . encode_length(strlen($value)) . $value;
}

function encode_integer(int $value): string
{
    if ($value === 0) {
        return "\0";
    }

    $bytes = '';
    while ($value > 0) {
        $bytes = chr($value & 0xff) . $bytes;
        $value >>= 8;
    }
    if ((ord($bytes[0]) & 0x80) !== 0) {
        $bytes = "\0" . $bytes;
    }
    return $bytes;
}

function build_bind_response(int $messageId): string
{
    $bindResponse = tlv(0x0a, "\0") . tlv(0x04, '') . tlv(0x04, '');
    return tlv(0x30, tlv(0x02, encode_integer($messageId)) . tlv(0x61, $bindResponse));
}

$options = parse_options($argv);
$portFile = isset($options['port-file']) && is_string($options['port-file']) ? $options['port-file'] : null;
$logFile = isset($options['log-file']) && is_string($options['log-file']) ? $options['log-file'] : null;
if ($portFile === null || $logFile === null) {
    fwrite(STDERR, "Usage: php mock-ldap-sasl-server.php --port-file <path> --log-file <path>\n");
    exit(2);
}

$server = null;
$client = null;
try {
    $server = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr, STREAM_SERVER_BIND | STREAM_SERVER_LISTEN);
    if ($server === false) {
        server_fail("Unable to listen on 127.0.0.1:0: {$errno} {$errstr}");
    }
    stream_set_timeout($server, 20);

    $address = stream_socket_get_name($server, false);
    if ($address === false || !preg_match('/:(\d+)$/', $address, $matches)) {
        server_fail('Unable to determine mock LDAP server port');
    }
    file_put_contents($portFile, json_encode(['port' => (int) $matches[1]], JSON_THROW_ON_ERROR));

    $client = stream_socket_accept($server, 20);
    if ($client === false) {
        server_fail('Timed out waiting for LDAP client connection');
    }
    stream_set_timeout($client, 5);

    $bind = parse_bind_request(read_ldap_packet($client));
    fwrite($client, build_bind_response((int) $bind['message_id']));
    fflush($client);

    $unbindSeen = false;
    stream_set_timeout($client, 2);
    $unbind = read_ldap_packet($client, false);
    if ($unbind !== null) {
        $unbindSeen = parse_unbind_request($unbind);
    }

    $event = [
        'message_id' => $bind['message_id'],
        'version' => $bind['version'],
        'name' => $bind['name'],
        'mechanism' => $bind['mechanism'],
        'credentials_base64' => base64_encode($bind['credentials']),
        'plain_parts' => $bind['plain_parts'],
        'unbind_seen' => $unbindSeen,
    ];
    file_put_contents($logFile, json_encode($event, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
    exit(0);
} catch (Throwable $throwable) {
    $event = [
        'error' => get_class($throwable) . ': ' . $throwable->getMessage(),
        'trace' => $throwable->getTraceAsString(),
    ];
    file_put_contents($logFile, json_encode($event, JSON_PRETTY_PRINT));
    fwrite(STDERR, $event['error'] . "\n");
    exit(1);
} finally {
    if (is_resource($client)) {
        fclose($client);
    }
    if (is_resource($server)) {
        fclose($server);
    }
}
