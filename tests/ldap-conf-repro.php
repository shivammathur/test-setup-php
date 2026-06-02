<?php
error_reporting(E_ALL);
ini_set('display_errors', '1');

$host = $argv[1] ?? 'localhost';
$port = (int) ($argv[2] ?? 4636);

$locations = openssl_get_cert_locations();
echo ($locations['default_cert_file'] ?? '') . PHP_EOL;
echo ($locations['default_cert_dir'] ?? '') . PHP_EOL;

$ldapconn = ldap_connect('ldaps://' . $host . ':' . $port)
  or die('No connection to LDAP server!' . PHP_EOL);

if ($ldapconn) {
    echo 'Connect success' . PHP_EOL;
}

$diag = '';
ldap_get_option($ldapconn, LDAP_OPT_DIAGNOSTIC_MESSAGE, $diag);
echo 'Diagnostic: ' . $diag . PHP_EOL;

ldap_set_option($ldapconn, LDAP_OPT_PROTOCOL_VERSION, 3);
ldap_set_option($ldapconn, LDAP_OPT_REFERRALS, 0);
ldap_set_option($ldapconn, LDAP_OPT_DEBUG_LEVEL, 255);
if (defined('LDAP_OPT_NETWORK_TIMEOUT')) {
    ldap_set_option($ldapconn, LDAP_OPT_NETWORK_TIMEOUT, 3);
}
if (defined('LDAP_OPT_TIMEOUT')) {
    ldap_set_option($ldapconn, LDAP_OPT_TIMEOUT, 3);
}

$ldapbind = @ldap_bind($ldapconn, 'cn=php22207', 'php22207');
if ($ldapbind) {
    echo 'LDAP bind successful...' . PHP_EOL;
} else {
    ldap_get_option($ldapconn, LDAP_OPT_DIAGNOSTIC_MESSAGE, $diag);
    echo 'Diagnostic: ' . $diag . PHP_EOL;
    echo 'LDAP Error: ' . ldap_error($ldapconn) . PHP_EOL;
    echo 'LDAP Errno: ' . ldap_errno($ldapconn) . PHP_EOL;

    $opensslErrors = [];
    while ($msg = openssl_error_string()) {
        $opensslErrors[] = $msg;
        echo 'OpenSSL: ' . $msg . PHP_EOL;
    }
}

$opensslErrors = $opensslErrors ?? [];
$ldapError = ldap_error($ldapconn);
$ldapErrno = ldap_errno($ldapconn);
$haystack = $diag . "\n" . $ldapError . "\n" . implode("\n", $opensslErrors);

$result = [
    'bind' => (bool) $ldapbind,
    'diagnostic' => $diag,
    'ldap_error' => $ldapError,
    'ldap_errno' => $ldapErrno,
    'openssl_errors' => $opensslErrors,
    'certificate_verify_failed' =>
        stripos($haystack, 'certificate verify failed') !== false ||
        stripos($haystack, 'unable to get local issuer certificate') !== false,
];

if (function_exists('ldap_close')) {
    ldap_close($ldapconn);
}

echo 'JSON_RESULT=' . json_encode($result, JSON_UNESCAPED_SLASHES) . PHP_EOL;
