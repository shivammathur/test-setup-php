<?php
function verify(bool $ok, string $message): void {
    if (!$ok) throw new RuntimeException($message);
}
foreach (['openssl', 'curl', 'ldap', 'pgsql', 'pdo_pgsql', 'gd', 'snmp'] as $extension) {
    verify(extension_loaded($extension), "$extension is missing");
}
$expected = match (PHP_MINOR_VERSION) {2, 3, 4 => '3.0.22', 5 => '3.5.8', 6 => '4.0.2'};
verify(str_starts_with(OPENSSL_VERSION_TEXT, "OpenSSL $expected "), 'Wrong OpenSSL headers: '.OPENSSL_VERSION_TEXT);
ob_start(); phpinfo(INFO_MODULES); $info = ob_get_clean();
verify(preg_match('/OpenSSL Library Version\s*=>\s*OpenSSL '.preg_quote($expected, '/').'\b/', $info) === 1, 'Wrong OpenSSL runtime');
$curl = curl_version();
verify(str_starts_with($curl['ssl_version'], "OpenSSL/$expected"), 'Wrong curl TLS runtime: '.$curl['ssl_version']);
verify($curl['version'] === '8.22.0', 'Wrong curl version');
verify(str_starts_with($curl['libssh_version'] ?? '', 'libssh2/1.11.1'), 'Wrong libssh2 version');
verify(preg_match('/PostgreSQL \(libpq\) Version\s*=>\s*(\S+)/', $info, $postgresql) === 1, 'Missing PostgreSQL client version');
$postgresqlVersion = $postgresql[1];
verify($postgresqlVersion === (PHP_MINOR_VERSION <= 3 ? '14.24' : '16.15'), 'Wrong PostgreSQL client version: '.$postgresqlVersion);
$key = openssl_pkey_new(['private_key_type' => OPENSSL_KEYTYPE_RSA, 'private_key_bits' => 2048]);
verify($key !== false, 'RSA key generation failed');
$public = openssl_pkey_get_details($key)['key'];
$message = 'Windows PHP security update validation';
verify(openssl_sign($message, $signature, $key, OPENSSL_ALGO_SHA256), 'Signing failed');
verify(openssl_verify($message, $signature, $public, OPENSSL_ALGO_SHA256) === 1, 'Signature verification failed');
verify(openssl_public_encrypt($message, $encrypted, $public, OPENSSL_PKCS1_OAEP_PADDING), 'RSA encryption failed');
verify(openssl_private_decrypt($encrypted, $decrypted, $key, OPENSSL_PKCS1_OAEP_PADDING), 'RSA decryption failed');
verify($decrypted === $message, 'RSA roundtrip mismatch');
$aesKey = random_bytes(32); $iv = random_bytes(12);
$ciphertext = openssl_encrypt($message, 'aes-256-gcm', $aesKey, OPENSSL_RAW_DATA, $iv, $tag);
verify($ciphertext !== false && openssl_decrypt($ciphertext, 'aes-256-gcm', $aesKey, OPENSSL_RAW_DATA, $iv, $tag) === $message, 'AES-GCM roundtrip failed');
$ldap = ldap_connect('ldap://127.0.0.1:389');
verify($ldap !== false && ldap_set_option($ldap, LDAP_OPT_PROTOCOL_VERSION, 3), 'LDAP initialization failed');
ldap_unbind($ldap);
$snmp = new SNMP(SNMP::VERSION_2c, '127.0.0.1', 'public', 10000, 0);
verify($snmp->close(), 'SNMP initialization failed');
verify(in_array('pgsql', PDO::getAvailableDrivers(), true), 'PDO PostgreSQL driver missing');
$image = imagecreatetruecolor(16, 16); imagefill($image, 0, 0, 0x204080);
ob_start(); imagepng($image); $png = ob_get_clean();
$decoded = imagecreatefromstring($png);
verify($decoded !== false && imagesx($decoded) === 16 && imagesy($decoded) === 16, 'GD image roundtrip failed');
echo json_encode(['php' => PHP_VERSION, 'openssl' => OPENSSL_VERSION_TEXT, 'curl_tls' => $curl['ssl_version'], 'libssh2' => $curl['libssh_version'] ?? null, 'pgsql' => $postgresqlVersion, 'extensions' => get_loaded_extensions()], JSON_PRETTY_PRINT), "\n";
echo "Security dependency runtime checks passed\n";
