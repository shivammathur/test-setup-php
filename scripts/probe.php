<?php
if (PHP_SAPI === 'cli') {
    parse_str($argv[1] ?? '', $_GET);
} else {
    header('Content-Type: application/json');
}
$warnings = [];
set_error_handler(function ($level, $message) use (&$warnings) {
    $warnings[] = $message;
    return true;
});
$result = [
    'php' => PHP_VERSION,
    'sapi' => PHP_SAPI,
    'pid' => getmypid(),
    'zts' => PHP_ZTS,
    'architecture' => PHP_INT_SIZE === 8 ? 'x64' : 'x86',
    'ldap_loaded' => extension_loaded('ldap'),
    'openssl' => defined('OPENSSL_VERSION_TEXT') ? OPENSSL_VERSION_TEXT : null,
];
try {
    $settings = json_decode(file_get_contents(__DIR__ . '/fixture.json'), true, flags: JSON_THROW_ON_ERROR);
    $mode = $_GET['mode'] ?? 'ldaps';
    $result['mode'] = $mode;
    $result['debug_option'] = ldap_set_option(null, LDAP_OPT_DEBUG_LEVEL, 7);
    $result['ca_option'] = ldap_set_option(null, LDAP_OPT_X_TLS_CACERTFILE, $settings['ca']);
    $result['verify_option'] = ldap_set_option(null, LDAP_OPT_X_TLS_REQUIRE_CERT, LDAP_OPT_X_TLS_DEMAND);
    ldap_set_option(null, LDAP_OPT_NETWORK_TIMEOUT, 3);
    $port = $settings['ports'][$mode];
    $uri = ($mode === 'starttls' ? 'ldap' : 'ldaps') . '://127.0.0.1:' . $port;
    $link = ldap_connect($uri);
    $result['connect'] = $link !== false;
    if ($link !== false) {
        ldap_set_option($link, LDAP_OPT_PROTOCOL_VERSION, 3);
        ldap_set_option($link, LDAP_OPT_REFERRALS, 0);
        $result['starttls'] = $mode === 'starttls' ? ldap_start_tls($link) : null;
        $result['bind'] = ldap_bind($link, 'cn=test,dc=example,dc=test', 'fixture-password');
        $result['errno'] = ldap_errno($link);
        $result['error'] = ldap_error($link);
        ldap_get_option($link, LDAP_OPT_DIAGNOSTIC_MESSAGE, $diagnostic);
        $result['diagnostic'] = $diagnostic;
        if ($result['bind']) {
            $search = ldap_search($link, 'dc=example,dc=test', '(objectClass=*)', ['cn']);
            $entries = $search === false ? [] : ldap_get_entries($link, $search);
            $result['search'] = ($entries['count'] ?? 0) === 1 && ($entries[0]['cn'][0] ?? '') === 'fixture-user';
            $result['bad_password_rejected'] = !ldap_bind($link, 'cn=test,dc=example,dc=test', 'wrong-password') && ldap_errno($link) === 49;
        }
        ldap_unbind($link);
    }
} catch (Throwable $error) {
    $result['exception'] = $error->getMessage();
}
$result['warnings'] = $warnings;
echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
