<?php

foreach (['openssl', 'curl', 'ldap', 'pgsql', 'pdo_pgsql', 'snmp'] as $extension) {
    if (!extension_loaded($extension)) {
        fwrite(STDERR, "Missing extension: $extension\n");
        exit(1);
    }
}
$version = curl_version();
if (($version['features'] & CURL_VERSION_SSL) === 0) {
    fwrite(STDERR, "curl has no TLS support\n");
    exit(2);
}
echo json_encode([
    'curl' => $version['version'],
    'curl_ssl' => $version['ssl_version'],
    'libpq' => PGSQL_LIBPQ_VERSION,
], JSON_THROW_ON_ERROR);
