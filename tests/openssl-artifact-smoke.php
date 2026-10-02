<?php

function ok(bool $condition, string $message): void {
    if (!$condition) {
        fwrite(STDERR, "not ok - {$message}\n");
        exit(1);
    }
    echo "ok - {$message}\n";
}

function temp_path(string $name): string {
    $dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'openssl4-artifact-' . getmypid();
    if (!is_dir($dir)) {
        mkdir($dir, 0777, true);
    }
    return $dir . DIRECTORY_SEPARATOR . $name;
}

function write_file(string $path, string $contents): string {
    file_put_contents($path, $contents);
    return $path;
}

function openssl_test_config(): string {
    return write_file(temp_path('openssl.cnf'), <<<'CNF'
[ req ]
distinguished_name = req_distinguished_name
prompt = no
req_extensions = v3_req

[ req_distinguished_name ]

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
subjectAltName = @alt_names

[ v3_cert ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = artifact.example
DNS.2 = www.artifact.example
IP.1 = 127.0.0.1
CNF);
}

function rsa_cert_pair(string $commonName): array {
    $config = openssl_test_config();
    $args = [
        'config' => $config,
        'digest_alg' => 'sha256',
        'private_key_bits' => 2048,
        'private_key_type' => OPENSSL_KEYTYPE_RSA,
    ];
    $key = openssl_pkey_new($args);
    ok($key instanceof OpenSSLAsymmetricKey, 'RSA key generation succeeds');

    $dn = [
        'countryName' => 'US',
        'stateOrProvinceName' => 'CA',
        'localityName' => 'San Francisco',
        'organizationName' => 'OpenSSL Artifact Test',
        'organizationalUnitName' => 'QA',
        'commonName' => $commonName,
        'emailAddress' => 'artifact@example.test',
    ];
    $csr = openssl_csr_new($dn, $key, $args);
    ok($csr instanceof OpenSSLCertificateSigningRequest, 'CSR creation succeeds');

    $subject = openssl_csr_get_subject($csr);
    ok($subject['CN'] === $commonName, 'CSR short subject contains CN');
    $longSubject = openssl_csr_get_subject($csr, false);
    ok($longSubject['commonName'] === $commonName, 'CSR long subject contains commonName');

    $cert = openssl_csr_sign($csr, null, $key, 30, $args + ['x509_extensions' => 'v3_cert'], 0x4d2);
    ok($cert instanceof OpenSSLCertificate, 'self-signed certificate creation succeeds');

    openssl_pkey_export($key, $keyPem, null, ['config' => $config]);
    openssl_x509_export($cert, $certPem);

    return [$key, $csr, $cert, $keyPem, $certPem];
}

function cn_only_cert_pair(string $commonName): array {
    $config = write_file(temp_path('openssl-cn-only.cnf'), <<<'CNF'
[ req ]
distinguished_name = req_distinguished_name
prompt = no

[ req_distinguished_name ]
CN = example.test
CNF);
    $args = [
        'config' => $config,
        'digest_alg' => 'sha256',
        'private_key_bits' => 2048,
        'private_key_type' => OPENSSL_KEYTYPE_RSA,
    ];
    $key = openssl_pkey_new($args);
    ok($key instanceof OpenSSLAsymmetricKey, 'CN-only RSA key generation succeeds');
    $csr = openssl_csr_new(['commonName' => $commonName], $key, $args);
    ok($csr instanceof OpenSSLCertificateSigningRequest, 'CN-only CSR creation succeeds');
    $cert = openssl_csr_sign($csr, null, $key, 30, $args, 0x4d3);
    ok($cert instanceof OpenSSLCertificate, 'CN-only certificate creation succeeds');
    openssl_pkey_export($key, $keyPem, null, ['config' => $config]);
    openssl_x509_export($cert, $certPem);
    return [$keyPem, $certPem];
}

function test_x509_csr_and_crypto(): void {
    [$key, $csr, $cert] = rsa_cert_pair('artifact.example');

    $publicKey = openssl_csr_get_public_key($csr);
    ok($publicKey instanceof OpenSSLAsymmetricKey, 'CSR public key extraction succeeds');
    ok(openssl_x509_check_private_key($cert, $key), 'certificate matches private key');
    ok(openssl_x509_verify($cert, $publicKey) === 1, 'certificate verifies with CSR public key');

    $details = openssl_pkey_get_details($key);
    ok($details['type'] === OPENSSL_KEYTYPE_RSA && isset($details['rsa']['n'], $details['rsa']['e']), 'RSA pkey details are populated');

    $parsed = openssl_x509_parse($cert);
    ok($parsed['subject']['CN'] === 'artifact.example', 'x509 short subject CN parses');
    ok($parsed['issuer']['CN'] === 'artifact.example', 'x509 short issuer CN parses');
    ok(isset($parsed['extensions']['subjectAltName']) && str_contains($parsed['extensions']['subjectAltName'], 'DNS:artifact.example'), 'subjectAltName extension parses');
    ok(isset($parsed['extensions']['authorityKeyIdentifier']) && $parsed['extensions']['authorityKeyIdentifier'] !== '', 'authorityKeyIdentifier extension parses');

    $parsedLong = openssl_x509_parse($cert, false);
    ok($parsedLong['subject']['commonName'] === 'artifact.example', 'x509 long subject commonName parses');
    ok($parsedLong['issuer']['commonName'] === 'artifact.example', 'x509 long issuer commonName parses');

    $data = 'OpenSSL 4 artifact payload';
    ok(openssl_sign($data, $signature, $key, OPENSSL_ALGO_SHA256), 'openssl_sign succeeds');
    ok(openssl_verify($data, $signature, $publicKey, OPENSSL_ALGO_SHA256) === 1, 'openssl_verify succeeds');

    ok(openssl_digest('abc', 'sha256') === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'openssl_digest sha256 succeeds');

    $iv = random_bytes(12);
    $secret = random_bytes(16);
    $ciphertext = openssl_encrypt($data, 'aes-128-gcm', $secret, OPENSSL_RAW_DATA, $iv, $tag);
    ok(is_string($ciphertext) && strlen($tag) === 16, 'openssl_encrypt aes-128-gcm succeeds');
    ok(openssl_decrypt($ciphertext, 'aes-128-gcm', $secret, OPENSSL_RAW_DATA, $iv, $tag) === $data, 'openssl_decrypt aes-128-gcm succeeds');
}

function test_ec_behavior(): void {
    ok(defined('OPENSSL_KEYTYPE_EC'), 'EC key type is available');
    $curves = openssl_get_curve_names();
    ok(in_array('prime256v1', $curves, true), 'prime256v1 curve is available');

    $ec = openssl_pkey_new(['ec' => ['curve_name' => 'prime256v1']]);
    ok($ec instanceof OpenSSLAsymmetricKey, 'named-curve EC key generation succeeds');
    $details = openssl_pkey_get_details($ec);
    ok($details['type'] === OPENSSL_KEYTYPE_EC && $details['ec']['curve_name'] === 'prime256v1', 'named-curve EC details parse');

    $d = hex2bin('8D0AC65AAEA0D6B96254C65817D4A143A9E7A03876F1A37D');
    $p = hex2bin('BDB6F4FE3E8B1D9E0DA8C0D46F4C318CEFE4AFE3B6B8551F');
    $a = hex2bin('BB8E5E8FBC115E139FE6A814FE48AAA6F0ADA1AA5DF91985');
    $b = hex2bin('1854BEBDC31B21B7AEFC80AB0ECD10D5B1B3308E6DBF11C1');
    $gX = hex2bin('4AD5F7048DE709AD51236DE65E4D4B482C836DC6E4106640');
    $gY = hex2bin('02BB3A02D4AAADACAE24817A4CA3A1B014B5270432DB27D2');
    $order = hex2bin('BDB6F4FE3E8B1D9E0DA8C0D40FC962195DFAE76F56564677');
    $custom = @openssl_pkey_new(['ec' => ['p' => $p, 'a' => $a, 'b' => $b, 'order' => $order, 'g_x' => $gX, 'g_y' => $gY, 'd' => $d]]);
    if (OPENSSL_VERSION_NUMBER >= 0x40000000) {
        ok($custom === false, 'OpenSSL 4 rejects EC custom params without crashing');
    } else {
        ok($custom === false || $custom instanceof OpenSSLAsymmetricKey, 'EC custom params call returns cleanly');
    }
}

function bmp_cn_cert(): string {
    return <<<'PEM'
-----BEGIN CERTIFICATE-----
MIIC9DCCAdygAwIBAgICEAUwDQYJKoZIhvcNAQELBQAwIzEhMB8GA1UEAx4YAGUA
eABhAG0AcABsAGUALgB0AGUAcwB0MB4XDTI2MDEwMTAwMDAwMFoXDTM2MDEwMTAw
MDAwMFowIzEhMB8GA1UEAx4YAGUAeABhAG0AcABsAGUALgB0AGUAcwB0MIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzVbyoKzngZTbtYTmDstRJp3BT935
Wq3T1shoIgBkbfjOfCbUEDd4Lb088JiL4dlBPeXK8cYtsol+MWbCBTyg1M/fpoAe
j7E1ILcUtsHDS3yLcJJ/PgA1VcmI4L93y4Qbs/hhOjLW9dcEzee1LW4o5GVEXb+S
bqB6TWZDX84tqxEPcCx4k5ByrYy5DM24opV2NMCDEnoH3BFtKXtPMU0wNWzVYHcz
CBxKbrDEbkuVuojO5F7jpGqdY2oVZ2AM5kT+NUzj4eypUoO3L3AIKbIW4jHsikZy
QmcjIlDBwFlIlwpFB6sO4q9ytmspFo0khKc0SlggG0M7CUBG+EyAjd+uUQIDAQAB
ozIwMDAMBgNVHRMBAf8EAjAAMAsGA1UdDwQEAwIFoDATBgNVHSUEDDAKBggrBgEF
BQcDATANBgkqhkiG9w0BAQsFAAOCAQEAJigG6ZnNiJPTADXyjzEq/DupFQukMyE5
YcAjvIr3A6CqAKJWycZ2xCC4ArMruxg7cCZKqtYxXniUUEXJnYqU6DVfg1V9wo5E
ZUt0b3ZtWiQhW2V5GOdnRqaonDUPlBJ1wzpY5Jh6iDXdws/CyAcXF7eQgT/ulUcL
PjY65hAbRcd/sPnIVDCHvQM+BtB4JDhgxvd6qyuuJDDudfDZ3LvhDgfklWGih/SZ
3oXIhvF7AgkCe/CvOcygw064s81AeaIvyGZAUWmD47KjaxAjcIxbhZM/OKo833KB
u9juhGwov7KV+akQPCoft2qXoUEdIxDQbI4rjloFNdNLooaSNF9p1w==
-----END CERTIFICATE-----
PEM;
}

function bmp_cn_key(): string {
    return <<<'PEM'
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAzVbyoKzngZTbtYTmDstRJp3BT935Wq3T1shoIgBkbfjOfCbU
EDd4Lb088JiL4dlBPeXK8cYtsol+MWbCBTyg1M/fpoAej7E1ILcUtsHDS3yLcJJ/
PgA1VcmI4L93y4Qbs/hhOjLW9dcEzee1LW4o5GVEXb+SbqB6TWZDX84tqxEPcCx4
k5ByrYy5DM24opV2NMCDEnoH3BFtKXtPMU0wNWzVYHczCBxKbrDEbkuVuojO5F7j
pGqdY2oVZ2AM5kT+NUzj4eypUoO3L3AIKbIW4jHsikZyQmcjIlDBwFlIlwpFB6sO
4q9ytmspFo0khKc0SlggG0M7CUBG+EyAjd+uUQIDAQABAoIBAHZw0p6PXTHHVTvM
no6mA/cMQ7b3yJ7faTOYgUgrhcJRI3lFREjeVfm8D+yPcRAiqpkzdO4ka7Nxz1Jb
fUpcAEEAbnaxq+8iPgzSzaXk+esOubeDKNXwdNM43jUU+9puJzSV7i8NqCRBlEnY
fw7nXbrwFpEksSgSdLk0ZWRbnsfuk8dw6s9LgpPx1WmLYHOhI5/Ck8wVr8+ubXUI
M6duusaBdBps49HsaokH6o+gnytSLDA0ty3ru6VUHVm9SK5eGjCYmxeuBy2woV8c
0DqvqidqLqfRsqw9vJy1tsuJYvZyt6ELJUzlIH/7DVaiYoeiSboH41KQy2D2ZpM+
3o2jsIECgYEA+fEUhshfi5Ka50sV0Pht/VuxzdQYLJZTFJbSjPep9FLd9taPekim
6+3Gxgp2Y8+QtBHdxXCpDt3hHc6Ti19DIXK+7rPvyx7USCAX2tYIWjr9Jt62MHZg
VA1ERyLeMABMJqH5RQo1D+Iynm+Owtey19TeK0I2hVT4nNx4embwBJkCgYEA0lEb
Jx2zUj536W+wY02pyVJfO0llsLUFg2rCmLNwQ/Zpk+yYbpLzUGhh4G7j8+0ZndjL
2/5YSy+ZLNAwyOhweXnRBHgbnwUUrvoejPrQPNCtJyzePdQ0XbNByuItE+dVSSGI
14LxdSyITvAUkpxiZieIJENig1Wzrt15Zpjo0nkCgYEApMH/du2k1fuZMvhy9CKf
VpDYP0cdfF7He14EgzpLBSyO9sTvJXu41PMTwb5p1legGqNgXmNqfctTNvPSnN/5
/5WFORLR8kJrSvQk5XOLY/dYowPSc1XFIALyzDW240t+50SEbbdRzRudpIUDRXss
gEvo+/kUuYWOsNBAdudeNpkCgYBjCxz9Y8hB7/cqcJWhfj5595evZNZFzEnnZIx1
uvMgnleD+QSj9gItmKqXNcGV6s+IfUMru/C6n5TD/NsskgH9wvdC4oknbw4ZhOKE
Q81zBla0vzV96oQqqDNQpwjReby5LtixnRG2u50Jh5g4nvrb3rwHT9CBxwdSTyxP
u6zRCQKBgQCyyTPyzcVeZV982RfZcZE0q4oR0b2Bcmdm5ZBS6KY9yKUxnLmvi8yo
xItkYMYF7M8H+EYSsIhbok4/qvfn7wAto0Ryk8tjenkZ3I/Dw0Xqphw1oiE/GpRa
fqTOTJ+2hrgGYINCSQNgYtbVgYTdzzn3UIKs9zzlZKyFMs//+Pl3RA==
-----END RSA PRIVATE KEY-----
PEM;
}

function run_tls_server(string $portFile, string $certFile, string $keyFile): void {
    $context = stream_context_create(['ssl' => [
        'local_cert' => $certFile,
        'local_pk' => $keyFile,
        'verify_peer' => false,
        'allow_self_signed' => true,
    ]]);
    $server = stream_socket_server('tls://127.0.0.1:0', $errno, $errstr, STREAM_SERVER_BIND | STREAM_SERVER_LISTEN, $context);
    if ($server === false) {
        fwrite(STDERR, "server failed: {$errno} {$errstr}\n");
        exit(1);
    }
    file_put_contents($portFile, stream_socket_get_name($server, false));
    $client = @stream_socket_accept($server, 10);
    if (is_resource($client)) {
        fwrite($client, "ok\n");
        fclose($client);
    }
    fclose($server);
}

function assert_peer_name_result(string $certPem, string $keyPem, bool $shouldConnect, string $label): void {
    $certFile = write_file(temp_path($label . '-cert.pem'), $certPem);
    $keyFile = write_file(temp_path($label . '-key.pem'), $keyPem);
    $portFile = temp_path($label . '-port.txt');
    @unlink($portFile);

    $extensionDir = ini_get('extension_dir');
    $cmd = [
        PHP_BINARY,
        '-n',
        '-d', 'extension_dir=' . $extensionDir,
        '-d', 'extension=openssl',
        __FILE__,
        '--tls-server',
        $portFile,
        $certFile,
        $keyFile,
    ];
    $proc = proc_open($cmd, [['pipe', 'r'], ['pipe', 'w'], ['pipe', 'w']], $pipes);
    ok(is_resource($proc), "{$label} TLS server starts");

    $address = null;
    for ($i = 0; $i < 100; $i++) {
        if (is_file($portFile) && filesize($portFile) > 0) {
            $address = trim(file_get_contents($portFile));
            break;
        }
        usleep(100000);
    }
    ok($address !== null, "{$label} TLS server publishes address");

    $warnings = [];
    set_error_handler(function(int $severity, string $message) use (&$warnings): bool {
        $warnings[] = $message;
        return true;
    });
    $context = stream_context_create(['ssl' => [
        'verify_peer' => false,
        'verify_peer_name' => true,
        'peer_name' => 'example.test',
        'SNI_enabled' => false,
    ]]);
    $client = stream_socket_client('tls://' . $address, $errno, $errstr, 5, STREAM_CLIENT_CONNECT, $context);
    restore_error_handler();

    if ($shouldConnect) {
        ok(is_resource($client), "{$label} CN peer-name match succeeds");
        fclose($client);
    } else {
        ok($client === false, "{$label} CN peer-name match is rejected");
        ok((bool) preg_grep('/Peer certificate CN=.*malformed|Peer certificate CN=.*did not match/', $warnings), "{$label} rejection reports CN verification failure");
    }

    foreach ($pipes as $pipe) {
        fclose($pipe);
    }
    proc_close($proc);
}

if (($argv[1] ?? null) === '--tls-server') {
    run_tls_server($argv[2], $argv[3], $argv[4]);
    exit(0);
}

ok(extension_loaded('openssl'), 'openssl extension is loaded');
$requireOpenSsl4 = !in_array('--allow-non-openssl4', $argv, true);
if ($requireOpenSsl4) {
    ok(OPENSSL_VERSION_NUMBER >= 0x40000000, 'OpenSSL 4 runtime is active: ' . OPENSSL_VERSION_TEXT);
} else {
    ok(OPENSSL_VERSION_NUMBER > 0, 'OpenSSL runtime is active: ' . OPENSSL_VERSION_TEXT);
}

test_x509_csr_and_crypto();
test_ec_behavior();

[$asciiKeyPem, $asciiCertPem] = cn_only_cert_pair('example.test');
assert_peer_name_result($asciiCertPem, $asciiKeyPem, true, 'ascii-cn');
assert_peer_name_result(bmp_cn_cert(), bmp_cn_key(), false, 'bmp-cn');

echo "OpenSSL artifact smoke test complete\n";
