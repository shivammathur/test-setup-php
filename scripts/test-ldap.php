<?php

declare(strict_types=1);

function pass(string $message): void
{
    echo "ok - {$message}\n";
}

function skip_test(string $message): void
{
    echo "skip - {$message}\n";
}

function fail_test(string $message): never
{
    fwrite(STDERR, "not ok - {$message}\n");
    exit(1);
}

function assert_true(bool $condition, string $message): void
{
    if (!$condition) {
        fail_test($message);
    }
    pass($message);
}

function assert_same(mixed $actual, mixed $expected, string $message): void
{
    if ($actual !== $expected) {
        fail_test($message . ' (expected ' . var_export($expected, true) . ', got ' . var_export($actual, true) . ')');
    }
    pass($message);
}

function assert_ldap(bool $condition, LDAP\Connection $connection, string $message): void
{
    if (!$condition) {
        fail_test($message . ': [' . ldap_errno($connection) . '] ' . ldap_error($connection));
    }
    pass($message);
}

function assert_result_success(
    LDAP\Connection $connection,
    LDAP\Result $result,
    string $message,
    ?array &$responseControls = null
): void {
    $errorCode = null;
    $matchedDn = null;
    $errorMessage = null;
    $referrals = null;
    $controls = null;
    assert_ldap(
        ldap_parse_result($connection, $result, $errorCode, $matchedDn, $errorMessage, $referrals, $controls),
        $connection,
        "parse result for {$message}"
    );
    if ((int) $errorCode !== 0) {
        fail_test("{$message}: LDAP result {$errorCode} " . ldap_err2str((int) $errorCode) . " {$errorMessage}");
    }
    $responseControls = is_array($controls) ? $controls : [];
    pass($message);
}

function tcp_probe(int $port, string $label): void
{
    $tcp = @fsockopen('127.0.0.1', $port, $socketErrno, $socketError, 5.0);
    assert_true(is_resource($tcp), "{$label} TCP port is reachable");
    fclose($tcp);
}

function connect_ldap(string $uri, string $label): LDAP\Connection
{
    $connection = @ldap_connect($uri);
    assert_true($connection instanceof LDAP\Connection, "ldap_connect() created {$label}");
    assert_ldap(ldap_set_option($connection, LDAP_OPT_PROTOCOL_VERSION, 3), $connection, "set protocol version 3 for {$label}");
    return $connection;
}

function bind_admin(LDAP\Connection $connection, string $label): void
{
    assert_ldap(
        @ldap_bind($connection, 'cn=admin,dc=example,dc=org', 'secret'),
        $connection,
        "simple bind on {$label}"
    );
}

function read_one(
    LDAP\Connection $connection,
    string $dn,
    string $filter,
    array $attributes,
    string $message
): array {
    $result = @ldap_read($connection, $dn, $filter, $attributes);
    assert_true($result instanceof LDAP\Result, "{$message}: ldap_read returned a result");
    assert_same(ldap_count_entries($connection, $result), 1, "{$message}: exactly one entry returned");
    $entries = ldap_get_entries($connection, $result);
    assert_same($entries['count'] ?? null, 1, "{$message}: ldap_get_entries count is one");
    ldap_free_result($result);
    return $entries[0];
}

function first_entry(LDAP\Connection $connection, LDAP\Result $result, string $message): LDAP\ResultEntry
{
    $entry = ldap_first_entry($connection, $result);
    assert_true($entry instanceof LDAP\ResultEntry, "{$message}: ldap_first_entry returned an entry");
    return $entry;
}

function collect_entries(LDAP\Connection $connection, LDAP\Result $result): array
{
    $entries = [];
    for ($entry = ldap_first_entry($connection, $result); $entry instanceof LDAP\ResultEntry; $entry = ldap_next_entry($connection, $entry)) {
        $entries[] = $entry;
    }
    return $entries;
}

function collect_uids(LDAP\Connection $connection, LDAP\Result $result): array
{
    $uids = [];
    foreach (collect_entries($connection, $result) as $entry) {
        $values = ldap_get_values($connection, $entry, 'uid');
        if (($values['count'] ?? 0) > 0) {
            $uids[] = $values[0];
        }
    }
    return $uids;
}

function assert_required_functions(): void
{
    $expected = [
        'ldap_add',
        'ldap_add_ext',
        'ldap_bind',
        'ldap_bind_ext',
        'ldap_close',
        'ldap_compare',
        'ldap_connect',
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
        'ldap_search',
        'ldap_set_option',
        'ldap_start_tls',
        'ldap_unbind',
    ];

    $available = get_extension_funcs('ldap') ?: [];
    $missing = array_values(array_diff($expected, $available));
    assert_same($missing, [], 'all expected PHP 8 LDAP functions are exported');

    foreach (['ldap_control_paged_result', 'ldap_control_paged_result_response', 'ldap_sort'] as $removed) {
        assert_true(!function_exists($removed), "{$removed} is not unexpectedly restored in PHP 8 builds");
    }
}

assert_true(extension_loaded('ldap'), 'ldap extension is loaded');
assert_required_functions();
assert_true(is_file('C:\\openldap\\sysconf\\ldap.conf'), 'OpenLDAP sysconf ldap.conf exists');

tcp_probe(1389, 'LDAP');
tcp_probe(1636, 'LDAPS');

$connection = connect_ldap('ldap://127.0.0.1:1389', 'plain LDAP connection');
if (function_exists('ldap_set_rebind_proc')) {
    assert_ldap(ldap_set_rebind_proc($connection, static fn (): int => 0), $connection, 'ldap_set_rebind_proc accepts a callback');
} else {
    skip_test('ldap_set_rebind_proc is not exported by this PHP LDAP build');
}

if (defined('LDAP_OPT_NETWORK_TIMEOUT')) {
    $networkTimeout = null;
    assert_ldap(ldap_get_option($connection, LDAP_OPT_NETWORK_TIMEOUT, $networkTimeout), $connection, 'read network timeout from ldap.conf');
    assert_same((int) $networkTimeout, 5, 'ldap.conf NETWORK_TIMEOUT is applied');
}
if (defined('LDAP_OPT_REFERRALS')) {
    $referrals = null;
    assert_ldap(ldap_get_option($connection, LDAP_OPT_REFERRALS, $referrals), $connection, 'read referrals option from ldap.conf');
    assert_same((int) $referrals, 0, 'ldap.conf REFERRALS off is applied');
}
if (defined('LDAP_OPT_DEREF') && defined('LDAP_DEREF_ALWAYS')) {
    $deref = null;
    assert_ldap(ldap_get_option($connection, LDAP_OPT_DEREF, $deref), $connection, 'read deref option from ldap.conf');
    assert_same((int) $deref, LDAP_DEREF_ALWAYS, 'ldap.conf DEREF always is applied');
}

$bindResult = @ldap_bind_ext($connection, 'cn=admin,dc=example,dc=org', 'secret');
assert_true($bindResult instanceof LDAP\Result, 'ldap_bind_ext returns a result');
assert_result_success($connection, $bindResult, 'ldap_bind_ext admin bind');

assert_ldap(
    @ldap_bind($connection, 'cn=admin,dc=example,dc=org', 'secret'),
    $connection,
    'simple bind through configured OpenLDAP client'
);

$root = @ldap_read($connection, '', '(objectClass=*)', ['namingContexts', 'supportedExtension', 'supportedControl', 'supportedSASLMechanisms']);
assert_true($root instanceof LDAP\Result, 'read root DSE');
assert_same(ldap_count_entries($connection, $root), 1, 'root DSE returned one entry');
$rootEntries = ldap_get_entries($connection, $root);
$rootEntry = $rootEntries[0];
$namingContexts = [];
foreach (($rootEntry['namingcontexts'] ?? []) as $key => $value) {
    if (is_int($key)) {
        $namingContexts[] = strtolower($value);
    }
}
assert_true(in_array('dc=example,dc=org', $namingContexts, true), 'root DSE exposes expected naming context');
if (defined('LDAP_EXOP_WHO_AM_I')) {
    assert_true(in_array(strtolower(LDAP_EXOP_WHO_AM_I), array_map('strtolower', array_filter($rootEntry['supportedextension'] ?? [], 'is_string')), true), 'root DSE advertises whoami exop');
}
if (defined('LDAP_CONTROL_PAGEDRESULTS')) {
    assert_true(in_array(strtolower(LDAP_CONTROL_PAGEDRESULTS), array_map('strtolower', array_filter($rootEntry['supportedcontrol'] ?? [], 'is_string')), true), 'root DSE advertises paged results control');
}
ldap_free_result($root);

$search = @ldap_search(
    $connection,
    'dc=example,dc=org',
    '(objectClass=inetOrgPerson)',
    ['dn', 'cn', 'mail', 'uid', 'userPassword'],
    0,
    0,
    0,
    LDAP_DEREF_NEVER
);
assert_true($search instanceof LDAP\Result, 'subtree search existing inetOrgPerson entries');
assert_same(ldap_count_entries($connection, $search), 3, 'subtree search returned three people');
$entries = ldap_get_entries($connection, $search);
assert_same($entries['count'] ?? null, 3, 'ldap_get_entries preserves search count');
$firstEntry = first_entry($connection, $search, 'people search');
$firstDn = ldap_get_dn($connection, $firstEntry);
assert_true(is_string($firstDn) && $firstDn !== '', 'ldap_get_dn returns first entry DN');
$ufn = ldap_dn2ufn($firstDn);
assert_true(is_string($ufn) && $ufn !== '', 'ldap_dn2ufn returns a friendly DN');
$dnParts = ldap_explode_dn($firstDn, 0);
assert_true(($dnParts['count'] ?? 0) > 0, 'ldap_explode_dn returns DN components');
$attributes = ldap_get_attributes($connection, $firstEntry);
assert_true(($attributes['count'] ?? 0) > 0, 'ldap_get_attributes returns attributes');
$attributeNames = [];
for ($attribute = ldap_first_attribute($connection, $firstEntry); is_string($attribute); $attribute = ldap_next_attribute($connection, $firstEntry)) {
    $attributeNames[] = strtolower($attribute);
}
assert_true(in_array('uid', $attributeNames, true), 'ldap_first_attribute/ldap_next_attribute enumerated uid');
$passwordValues = ldap_get_values_len($connection, $firstEntry, 'userPassword');
assert_true(($passwordValues['count'] ?? 0) > 0, 'ldap_get_values_len reads binary-safe values');
assert_true(ldap_first_reference($connection, $search) === false, 'ldap_first_reference reports no references in normal search');
assert_same(ldap_count_references($connection, $search), 0, 'ldap_count_references reports no references in normal search');
ldap_free_result($search);

$list = @ldap_list($connection, 'dc=example,dc=org', '(ou=*)', ['ou']);
assert_true($list instanceof LDAP\Result, 'ldap_list performs one-level search');
$ous = [];
foreach (collect_entries($connection, $list) as $entry) {
    $values = ldap_get_values($connection, $entry, 'ou');
    if (($values['count'] ?? 0) > 0) {
        $ous[] = $values[0];
    }
}
sort($ous);
assert_same($ous, ['Groups', 'People'], 'ldap_list found expected organizational units');
ldap_free_result($list);

$aliceDn = 'uid=alice,ou=People,dc=example,dc=org';
assert_true(ldap_compare($connection, $aliceDn, 'mail', 'alice@example.org') === true, 'ldap_compare true case works');
assert_true(ldap_compare($connection, $aliceDn, 'mail', 'nobody@example.org') === false, 'ldap_compare false case works');

assert_ldap(@ldap_modify($connection, $aliceDn, ['telephoneNumber' => ['+1 555 0101']]), $connection, 'ldap_modify replaces telephoneNumber');
$verify = read_one($connection, $aliceDn, '(objectClass=*)', ['telephoneNumber'], 'verify ldap_modify');
assert_same($verify['telephonenumber'][0] ?? null, '+1 555 0101', 'ldap_modify attribute round-trips');

assert_ldap(@ldap_mod_add($connection, $aliceDn, ['description' => ['plain mod_add']]), $connection, 'ldap_mod_add adds description');
assert_ldap(@ldap_mod_replace($connection, $aliceDn, ['description' => ['plain mod_replace']]), $connection, 'ldap_mod_replace replaces description');
assert_ldap(@ldap_mod_del($connection, $aliceDn, ['description' => ['plain mod_replace']]), $connection, 'ldap_mod_del deletes description');

$responseControls = [];
$modControls = [];
if (defined('LDAP_CONTROL_PRE_READ') && defined('LDAP_CONTROL_POST_READ')) {
    $modControls = [
        ['oid' => LDAP_CONTROL_PRE_READ, 'iscritical' => true, 'value' => ['attrs' => ['title']]],
        ['oid' => LDAP_CONTROL_POST_READ, 'iscritical' => true, 'value' => ['attrs' => ['title']]],
    ];
}
$modResult = @ldap_mod_add_ext($connection, $aliceDn, ['description' => ['ext add']], $modControls ?: null);
assert_true($modResult instanceof LDAP\Result, 'ldap_mod_add_ext returns a result');
assert_result_success($connection, $modResult, 'ldap_mod_add_ext adds description', $responseControls);
if ($modControls !== []) {
    assert_true(isset($responseControls[LDAP_CONTROL_POST_READ]), 'post-read response control returned for ldap_mod_add_ext');
}
$modResult = @ldap_mod_replace_ext($connection, $aliceDn, ['description' => ['ext replace']]);
assert_true($modResult instanceof LDAP\Result, 'ldap_mod_replace_ext returns a result');
assert_result_success($connection, $modResult, 'ldap_mod_replace_ext replaces description');
$modResult = @ldap_mod_del_ext($connection, $aliceDn, ['description' => ['ext replace']]);
assert_true($modResult instanceof LDAP\Result, 'ldap_mod_del_ext returns a result');
assert_result_success($connection, $modResult, 'ldap_mod_del_ext deletes description');

assert_ldap(
    @ldap_modify_batch($connection, $aliceDn, [
        ['attrib' => 'description', 'modtype' => LDAP_MODIFY_BATCH_ADD, 'values' => ['batch one', 'batch two']],
        ['attrib' => 'title', 'modtype' => LDAP_MODIFY_BATCH_REPLACE, 'values' => ['Senior Engineer']],
    ]),
    $connection,
    'ldap_modify_batch add and replace'
);
assert_ldap(
    @ldap_modify_batch($connection, $aliceDn, [
        ['attrib' => 'description', 'modtype' => LDAP_MODIFY_BATCH_REMOVE, 'values' => ['batch one']],
        ['attrib' => 'description', 'modtype' => LDAP_MODIFY_BATCH_REMOVE_ALL],
    ]),
    $connection,
    'ldap_modify_batch remove values and attribute'
);

$binary = "\x00\x01PHP-LDAP\xff";
assert_ldap(@ldap_mod_add($connection, $aliceDn, ['jpegPhoto' => [$binary]]), $connection, 'add binary jpegPhoto value');
$binaryResult = @ldap_read($connection, $aliceDn, '(objectClass=*)', ['jpegPhoto']);
assert_true($binaryResult instanceof LDAP\Result, 'read binary jpegPhoto');
$binaryEntry = first_entry($connection, $binaryResult, 'binary read');
$binaryValues = ldap_get_values_len($connection, $binaryEntry, 'jpegPhoto');
assert_same($binaryValues[0] ?? null, $binary, 'ldap_get_values_len preserves binary value');
ldap_free_result($binaryResult);
assert_ldap(@ldap_mod_del($connection, $aliceDn, ['jpegPhoto' => [$binary]]), $connection, 'delete binary jpegPhoto value');

$bobDn = 'uid=bob,ou=People,dc=example,dc=org';
$bob = [
    'objectClass' => ['top', 'person', 'organizationalPerson', 'inetOrgPerson'],
    'cn' => 'Bob Example',
    'sn' => 'Example',
    'uid' => 'bob',
    'mail' => 'bob@example.org',
    'userPassword' => 'bob-secret',
];
assert_ldap(@ldap_add($connection, $bobDn, $bob), $connection, 'ldap_add adds Bob entry');
assert_true(@ldap_add($connection, $bobDn, $bob) === false, 'duplicate ldap_add fails cleanly');
assert_true(ldap_errno($connection) !== 0, 'ldap_errno captures duplicate add error');
assert_true(is_string(ldap_error($connection)) && ldap_error($connection) !== '', 'ldap_error captures duplicate add error');
assert_true(is_string(ldap_err2str(ldap_errno($connection))) && ldap_err2str(ldap_errno($connection)) !== '', 'ldap_err2str maps duplicate add error');
assert_true(ldap_compare($connection, $bobDn, 'uid', 'bob') === true, 'compare Bob uid');
assert_ldap(@ldap_delete($connection, $bobDn), $connection, 'ldap_delete removes Bob entry');

$daveDn = 'uid=dave,ou=People,dc=example,dc=org';
$dave = [
    'objectClass' => ['top', 'person', 'organizationalPerson', 'inetOrgPerson'],
    'cn' => 'Dave Example',
    'sn' => 'Example',
    'uid' => 'dave',
    'mail' => 'dave@example.org',
    'userPassword' => 'dave-secret',
];
$addResult = @ldap_add_ext($connection, $daveDn, $dave);
assert_true($addResult instanceof LDAP\Result, 'ldap_add_ext returns a result');
assert_result_success($connection, $addResult, 'ldap_add_ext adds Dave entry');
$renamedDaveDn = 'uid=david,ou=People,dc=example,dc=org';
assert_ldap(@ldap_rename($connection, $daveDn, 'uid=david', 'ou=People,dc=example,dc=org', true), $connection, 'ldap_rename renames Dave entry');
$deleteResult = @ldap_delete_ext($connection, $renamedDaveDn);
assert_true($deleteResult instanceof LDAP\Result, 'ldap_delete_ext returns a result');
assert_result_success($connection, $deleteResult, 'ldap_delete_ext removes renamed Dave entry');

$erinDn = 'uid=erin,ou=People,dc=example,dc=org';
$erin = [
    'objectClass' => ['top', 'person', 'organizationalPerson', 'inetOrgPerson'],
    'cn' => 'Erin Example',
    'sn' => 'Example',
    'uid' => 'erin',
    'mail' => 'erin@example.org',
    'userPassword' => 'erin-secret',
];
$addResult = @ldap_add_ext($connection, $erinDn, $erin);
assert_true($addResult instanceof LDAP\Result, 'ldap_add_ext returns a result for Erin');
assert_result_success($connection, $addResult, 'ldap_add_ext adds Erin entry');
$renameResult = @ldap_rename_ext($connection, $erinDn, 'uid=erin-renamed', 'ou=People,dc=example,dc=org', true);
assert_true($renameResult instanceof LDAP\Result, 'ldap_rename_ext returns a result');
assert_result_success($connection, $renameResult, 'ldap_rename_ext renames Erin entry');
$deleteResult = @ldap_delete_ext($connection, 'uid=erin-renamed,ou=People,dc=example,dc=org');
assert_true($deleteResult instanceof LDAP\Result, 'ldap_delete_ext returns a result for Erin');
assert_result_success($connection, $deleteResult, 'ldap_delete_ext removes Erin entry');

if (defined('LDAP_CONTROL_PAGEDRESULTS')) {
    $cookie = '';
    $pagedUids = [];
    do {
        $paged = @ldap_search(
            $connection,
            'ou=People,dc=example,dc=org',
            '(objectClass=inetOrgPerson)',
            ['uid'],
            0,
            0,
            0,
            LDAP_DEREF_NEVER,
            [['oid' => LDAP_CONTROL_PAGEDRESULTS, 'iscritical' => true, 'value' => ['size' => 1, 'cookie' => $cookie]]]
        );
        assert_true($paged instanceof LDAP\Result, 'paged ldap_search returns a result');
        $pagedUids = array_merge($pagedUids, collect_uids($connection, $paged));
        $controls = [];
        assert_result_success($connection, $paged, 'parse paged search result', $controls);
        $cookie = $controls[LDAP_CONTROL_PAGEDRESULTS]['value']['cookie'] ?? '';
        ldap_free_result($paged);
    } while ($cookie !== '');
    sort($pagedUids);
    assert_same($pagedUids, ['alice', 'brian', 'carol'], 'paged results returned all people');
}

if (defined('LDAP_CONTROL_SORTREQUEST') && defined('LDAP_CONTROL_SORTRESPONSE')) {
    $sorted = @ldap_search(
        $connection,
        'ou=People,dc=example,dc=org',
        '(objectClass=inetOrgPerson)',
        ['uid'],
        0,
        0,
        0,
        LDAP_DEREF_NEVER,
        [['oid' => LDAP_CONTROL_SORTREQUEST, 'iscritical' => true, 'value' => [['attr' => 'uid']]]]
    );
    assert_true($sorted instanceof LDAP\Result, 'server-side sorted ldap_search returns a result');
    $controls = [];
    assert_result_success($connection, $sorted, 'parse sorted search result', $controls);
    assert_same($controls[LDAP_CONTROL_SORTRESPONSE]['value']['errcode'] ?? null, 0, 'sort response reports success');
    assert_same(collect_uids($connection, $sorted), ['alice', 'brian', 'carol'], 'server-side sort returned uid order');
    ldap_free_result($sorted);
}

if (defined('LDAP_CONTROL_ASSERT')) {
    $assertResult = @ldap_mod_replace_ext(
        $connection,
        $aliceDn,
        ['title' => ['Asserted Engineer']],
        [['oid' => LDAP_CONTROL_ASSERT, 'iscritical' => true, 'value' => ['filter' => '(uid=alice)']]]
    );
    assert_true($assertResult instanceof LDAP\Result, 'ldap_mod_replace_ext with assertion control returns a result');
    assert_result_success($connection, $assertResult, 'assertion control permits matching modify');
}

$whoami = ldap_exop_whoami($connection);
assert_same($whoami, 'dn:cn=admin,dc=example,dc=org', 'ldap_exop_whoami returns bound admin identity');

if (defined('LDAP_EXOP_WHO_AM_I')) {
    $responseData = null;
    $responseOid = null;
    $exop = ldap_exop($connection, LDAP_EXOP_WHO_AM_I, null, null, $responseData, $responseOid);
    assert_true($exop === true || $exop instanceof LDAP\Result, 'ldap_exop WHOAMI returns success');
    if ($exop instanceof LDAP\Result) {
        assert_ldap(ldap_parse_exop($connection, $exop, $responseData, $responseOid), $connection, 'ldap_parse_exop parses WHOAMI result');
    }
    assert_same($responseData, 'dn:cn=admin,dc=example,dc=org', 'generic ldap_exop WHOAMI returns bound admin identity');
}

$passwordChanged = @ldap_exop_passwd($connection, 'uid=carol,ou=People,dc=example,dc=org', 'carol-secret', 'carol-new-secret');
assert_true($passwordChanged === true, 'ldap_exop_passwd changes Carol password');
$carolConnection = connect_ldap('ldap://127.0.0.1:1389', 'Carol password verification connection');
assert_ldap(@ldap_bind($carolConnection, 'uid=carol,ou=People,dc=example,dc=org', 'carol-new-secret'), $carolConnection, 'Carol can bind with changed password');
ldap_unbind($carolConnection);
assert_true(@ldap_exop_passwd($connection, 'uid=carol,ou=People,dc=example,dc=org', 'carol-new-secret', 'carol-secret') === true, 'ldap_exop_passwd restores Carol password');

if (function_exists('ldap_sasl_bind')) {
    $saslConnection = connect_ldap('ldap://127.0.0.1:1389', 'SASL PLAIN connection');
    $sasl = @ldap_sasl_bind($saslConnection, null, 'secret', 'PLAIN', null, 'cn=admin,dc=example,dc=org');
    if ($sasl) {
        pass('ldap_sasl_bind PLAIN succeeds');
        assert_same(ldap_exop_whoami($saslConnection), 'dn:cn=admin,dc=example,dc=org', 'SASL PLAIN bind identity is admin');
    } else {
        skip_test('ldap_sasl_bind PLAIN is unavailable in this OpenLDAP/PHP build: ' . ldap_error($saslConnection));
    }
    ldap_unbind($saslConnection);
} else {
    skip_test('ldap_sasl_bind is not exported by this OpenLDAP/PHP build');
}

$startTlsConnection = connect_ldap('ldap://127.0.0.1:1389', 'StartTLS connection');
assert_ldap(@ldap_start_tls($startTlsConnection), $startTlsConnection, 'ldap_start_tls upgrades the LDAP connection');
bind_admin($startTlsConnection, 'StartTLS connection');
$tlsRoot = read_one($startTlsConnection, '', '(objectClass=*)', ['namingContexts'], 'StartTLS root DSE read');
assert_true(($tlsRoot['namingcontexts']['count'] ?? 0) > 0, 'StartTLS connection can read root DSE');
ldap_unbind($startTlsConnection);

$ldapsConnection = connect_ldap('ldaps://127.0.0.1:1636', 'LDAPS connection');
bind_admin($ldapsConnection, 'LDAPS connection');
$ldapsRoot = read_one($ldapsConnection, '', '(objectClass=*)', ['namingContexts'], 'LDAPS root DSE read');
assert_true(($ldapsRoot['namingcontexts']['count'] ?? 0) > 0, 'LDAPS connection can read root DSE');
ldap_unbind($ldapsConnection);

$escapedFilter = ldap_escape('alice*)(uid=*)', '', LDAP_ESCAPE_FILTER);
assert_same($escapedFilter, 'alice\\2a\\29\\28uid=\\2a\\29', 'ldap_escape filter escaping is stable');
$escapedDn = ldap_escape('cn=Alice,ou=People', '', LDAP_ESCAPE_DN);
assert_same($escapedDn, 'cn\\3dAlice\\2cou\\3dPeople', 'ldap_escape DN escaping is stable');

if (function_exists('ldap_8859_to_t61') && function_exists('ldap_t61_to_8859')) {
    assert_same(ldap_t61_to_8859(ldap_8859_to_t61('Cafe')), 'Cafe', 'ldap_8859_to_t61/ldap_t61_to_8859 round-trip ASCII');
} else {
    skip_test('legacy T.61 conversion helpers are not exported by this PHP 8 LDAP build');
}

$closeConnection = connect_ldap('ldap://127.0.0.1:1389', 'ldap_close alias connection');
bind_admin($closeConnection, 'ldap_close alias connection');
assert_true(ldap_close($closeConnection), 'ldap_close alias completes');

ldap_unbind($connection);
pass('ldap_unbind completed');
pass('PHP LDAP artifact QA completed');
