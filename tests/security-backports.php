<?php
if (!extension_loaded('snmp') || !extension_loaded('intl')) {
    throw new RuntimeException('SNMP and Intl must be loaded');
}
$expectedIcu = PHP_MINOR_VERSION === 2 ? '71.1' : '72.1';
if (INTL_ICU_VERSION !== $expectedIcu) {
    throw new RuntimeException('Unexpected ICU version: '.INTL_ICU_VERSION);
}
if (!snmp_read_mib(getenv('MIBDIRS').'/SECURITY-TEST-MIB.txt')) {
    throw new RuntimeException('SNMP MIB loading failed');
}
$session = new SNMP(SNMP::VERSION_2c, '127.0.0.1', 'public', 10000, 0);
if (!$session->close()) {
    throw new RuntimeException('SNMP session lifecycle failed');
}
$collator = new Collator('de_DE');
$values = ['z', 'ä', 'a'];
if (!$collator->sort($values) || $values !== ['a', 'ä', 'z']) {
    throw new RuntimeException('ICU collation failed');
}
$normalized = Normalizer::normalize("e\u{0301}", Normalizer::FORM_C);
if ($normalized !== 'é') {
    throw new RuntimeException('ICU normalization failed');
}
echo json_encode(['php' => PHP_VERSION, 'icu' => INTL_ICU_VERSION, 'snmp' => 'passed', 'intl' => 'passed']), "\n";
