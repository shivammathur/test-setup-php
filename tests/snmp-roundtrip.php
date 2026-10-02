<?php
// Disposable agent bound only to loopback on the GitHub Actions runner.
$endpoint = $argv[1];
$oid = '.1.3.6.1.2.1.1.1.0';
$v2 = new SNMP(SNMP::VERSION_2c, $endpoint, 'release-community', 1000000, 1);
$v2->valueretrieval = SNMP_VALUE_PLAIN;
$plain = $v2->get($oid);
if (!is_string($plain) || $plain !== 'Winlibs OpenSSL release validation') {
    throw new RuntimeException('Unexpected SNMPv2 response: ' . var_export($plain, true));
}
$v3 = new SNMP(SNMP::VERSION_3, $endpoint, 'releaseqa', 1000000, 1);
$v3->valueretrieval = SNMP_VALUE_PLAIN;
if (!$v3->setSecurity('authPriv', 'SHA', 'ReleaseAuthOnlyForTests', 'AES', 'ReleasePrivacyOnlyForTests')) {
    throw new RuntimeException('SNMPv3 security setup failed');
}
$encrypted = $v3->get($oid);
if ($encrypted !== $plain) {
    throw new RuntimeException('Authenticated encrypted SNMPv3 round trip failed');
}
$wrong = new SNMP(SNMP::VERSION_3, $endpoint, 'releaseqa', 200000, 0);
$wrong->setSecurity('authPriv', 'SHA', 'DeliberatelyWrongAuth', 'AES', 'ReleasePrivacyOnlyForTests');
if (@$wrong->get($oid) !== false) {
    throw new RuntimeException('SNMPv3 accepted incorrect authentication');
}
echo json_encode(['snmpV2'=>true, 'snmpV3ShaAes'=>true, 'wrongAuthenticationRejected'=>true], JSON_THROW_ON_ERROR);
