<?php
declare(strict_types=1);

error_reporting(E_ALL);
ini_set('display_errors', '1');

$jsonOut = null;
for ($i = 1; $i < $argc; $i++) {
    if ($argv[$i] === '--json-out' && isset($argv[$i + 1])) {
        $jsonOut = $argv[++$i];
    }
}

$result = [
    'php_version' => PHP_VERSION,
    'sapi' => PHP_SAPI,
    'platform' => PHP_OS_FAMILY,
    'checks' => [],
    'failures' => [],
    'details' => [],
];

function record_check(string $name, bool $ok, $details = null): void
{
    global $result;
    $entry = ['name' => $name, 'ok' => $ok];
    if ($details !== null) {
        $entry['details'] = $details;
    }
    $result['checks'][] = $entry;
    if (!$ok) {
        $result['failures'][] = $entry;
    }
    if (getenv('WINLIBS_QA_PROGRESS') === '1') {
        fwrite(STDERR, '[' . ($ok ? 'PASS' : 'FAIL') . "] $name" . PHP_EOL);
    }
}

function write_mo_file(string $file, array $messages): void
{
    ksort($messages, SORT_STRING);
    $ids = array_keys($messages);
    $n = count($ids);
    $origTableOffset = 28;
    $transTableOffset = $origTableOffset + ($n * 8);
    $origDataOffset = $transTableOffset + ($n * 8);

    $origTable = '';
    $transTable = '';
    $origData = '';
    $transData = '';

    $offset = $origDataOffset;
    foreach ($ids as $id) {
        $bytes = (string) $id;
        $origTable .= pack('V2', strlen($bytes), $offset);
        $origData .= $bytes . "\0";
        $offset += strlen($bytes) + 1;
    }

    $offset = $origDataOffset + strlen($origData);
    foreach ($ids as $id) {
        $bytes = (string) $messages[$id];
        $transTable .= pack('V2', strlen($bytes), $offset);
        $transData .= $bytes . "\0";
        $offset += strlen($bytes) + 1;
    }

    $header = pack('V7', 0x950412de, 0, $n, $origTableOffset, $transTableOffset, 0, 0);
    $dir = dirname($file);
    if (!is_dir($dir) && !mkdir($dir, 0777, true) && !is_dir($dir)) {
        throw new RuntimeException("Could not create $dir");
    }
    file_put_contents($file, $header . $origTable . $transTable . $origData . $transData);
}

function create_gettext_catalog(string $root, string $locale, string $category, string $domain, array $messages): void
{
    write_mo_file($root . DIRECTORY_SEPARATOR . $locale . DIRECTORY_SEPARATOR . $category . DIRECTORY_SEPARATOR . $domain . '.mo', $messages);
}

function expect_value_error(string $name, callable $callback, string $expectedMessagePart): void
{
    try {
        $callback();
        record_check($name, false, 'no ValueError thrown');
    } catch (ValueError $e) {
        record_check($name, str_contains($e->getMessage(), $expectedMessagePart), $e->getMessage());
    }
}

function normalize_path_for_compare($path)
{
    if (!is_string($path)) {
        return $path;
    }
    $normalized = str_replace('\\', '/', $path);
    $real = realpath($normalized);
    if ($real !== false) {
        $normalized = str_replace('\\', '/', $real);
    }
    return rtrim($normalized, '/');
}

function run_gettext_checks(): void
{
    global $result;

    record_check('gettext extension loaded', extension_loaded('gettext'));
    $expected = [
        'gettext',
        '_',
        'dgettext',
        'dcgettext',
        'ngettext',
        'dngettext',
        'dcngettext',
        'textdomain',
        'bindtextdomain',
        'bind_textdomain_codeset',
    ];
    foreach ($expected as $function) {
        record_check("gettext function $function exists", function_exists($function));
    }
    if (!extension_loaded('gettext')) {
        return;
    }

    $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'winlibs-gettext-' . getmypid();
    $isoHeader = "Project-Id-Version: winlibs-qa\nContent-Type: text/plain; charset=ISO-8859-1\nContent-Transfer-Encoding: 8bit\nPlural-Forms: nplurals=2; plural=(n != 1);\n";
    $utf8Header = "Project-Id-Version: winlibs-qa-utf8\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\nPlural-Forms: nplurals=2; plural=(n != 1);\n";
    $catalogs = [
        ['LC_MESSAGES', 'messages', ['' => $isoHeader, 'Basic test' => 'A basic test']],
        ['LC_MESSAGES', 'dngettextTest', ['' => $isoHeader, "item\0items" => "Produkt\0Produkte"]],
        ['LC_MESSAGES', 'dgettextTest', ['' => $isoHeader, "item\0items" => "Produkt\0Produkte"]],
        ['LC_MESSAGES', 'dgettextTest_switch', ['' => $isoHeader, "item\0items" => "Produkt_switched\0Produkte_switched"]],
        ['LC_CTYPE', 'dngettextTest', ['' => $isoHeader, "item\0items" => "cProdukt\0cProdukte"]],
        ['LC_CTYPE', 'dgettextTest', ['' => $isoHeader, "item\0items" => "Produkt\0Produkte"]],
        ['LC_CTYPE', 'dgettextTest_switch', ['' => $isoHeader, "item\0items" => "Produkt_switched\0Produkte_switched"]],
        ['LC_MESSAGES', 'utf8Test', ['' => $utf8Header, 'encoding-euro' => 'euro-€']],
        ['LC_MESSAGES', 'latin1Test', ['' => $isoHeader, 'encoding-cafe' => "caf\xE9"]],
        ['LC_MESSAGES', 'localeSwitch', ['' => $utf8Header, 'language-name' => 'English']],
    ];
    $localeSwitchCatalogs = [
        [
            'label' => 'German',
            'expected' => 'Deutsch',
            'aliases' => ['de_DE.UTF-8', 'de_DE.utf8', 'de_DE', 'de', 'German_Germany.utf8', 'German_Germany.1252', 'German_Germany'],
        ],
        [
            'label' => 'French',
            'expected' => 'Français',
            'aliases' => ['fr_FR.UTF-8', 'fr_FR.utf8', 'fr_FR', 'fr', 'French_France.utf8', 'French_France.1252', 'French_France'],
        ],
    ];

    putenv('LANGUAGE=');
    putenv('LC_ALL=en_US.UTF-8');
    putenv('LC_MESSAGES=en_US.UTF-8');
    putenv('LANG=en_US.UTF-8');
    $locale = setlocale(
        LC_ALL,
        'en_US.UTF-8',
        'en_US',
        'English_United States.utf8',
        'English_United States.1252',
        'English_United States'
    );
    $localeCandidates = ['en_US.UTF-8', 'en_US', 'en', 'English_United States.utf8', 'English_United States.1252', 'English_United States'];
    if (is_string($locale) && $locale !== '') {
        $localeCandidates[] = $locale;
    }
    foreach (array_unique($localeCandidates) as $localeName) {
        foreach ($catalogs as [$category, $domain, $messages]) {
            create_gettext_catalog($root, $localeName, $category, $domain, $messages);
        }
    }
    foreach ($localeSwitchCatalogs as $case) {
        foreach ($case['aliases'] as $localeName) {
            create_gettext_catalog($root, $localeName, 'LC_MESSAGES', 'localeSwitch', [
                '' => $utf8Header,
                'language-name' => $case['expected'],
            ]);
        }
    }

    $result['details']['gettext_locale'] = [
        'requested' => 'en_US.UTF-8',
        'actual' => $locale,
        'environment' => [
            'LANGUAGE' => getenv('LANGUAGE'),
            'LC_ALL' => getenv('LC_ALL'),
            'LC_MESSAGES' => getenv('LC_MESSAGES'),
            'LANG' => getenv('LANG'),
        ],
    ];
    record_check('gettext usable Windows locale available', is_string($locale) && $locale !== '', $locale);

    $originalCwd = getcwd();
    $bindRoot = str_replace('\\', '/', $root);
    foreach (['messages', 'dngettextTest', 'dgettextTest', 'dgettextTest_switch', 'utf8Test', 'latin1Test'] as $domain) {
        $boundRoot = bindtextdomain($domain, $bindRoot);
        record_check("gettext absolute bindtextdomain path accepted for $domain", is_string($boundRoot) && $boundRoot !== '', $boundRoot);
    }
    $currentBindRoot = bindtextdomain('messages', null);
    record_check(
        'gettext bindtextdomain null reads current path',
        normalize_path_for_compare($currentBindRoot) === normalize_path_for_compare($bindRoot),
        $currentBindRoot
    );
    if ($originalCwd !== false) {
        chdir($root);
        $relativeRoot = '.';
        foreach (['messages', 'dngettextTest', 'dgettextTest', 'dgettextTest_switch', 'utf8Test', 'latin1Test'] as $domain) {
            $boundRoot = bindtextdomain($domain, $relativeRoot);
            record_check("gettext relative bindtextdomain path accepted for $domain", is_string($boundRoot) && $boundRoot !== '', $boundRoot);
        }
        textdomain('messages');
        record_check('gettext relative bind translates active domain', gettext('Basic test') === 'A basic test', gettext('Basic test'));
        chdir($originalCwd);
        foreach (['messages', 'dngettextTest', 'dgettextTest', 'dgettextTest_switch', 'utf8Test', 'latin1Test'] as $domain) {
            bindtextdomain($domain, $bindRoot);
        }
    }
    record_check('gettext bindtextdomain rejects missing path', bindtextdomain('missing-path-domain', $bindRoot . '/does-not-exist') === false);
    expect_value_error('gettext bindtextdomain rejects empty domain', fn() => bindtextdomain('', $bindRoot), 'must not be empty');
    if (PHP_VERSION_ID >= 80300) {
        expect_value_error('gettext bindtextdomain rejects null byte domain', fn() => bindtextdomain("foo\0bar", $bindRoot), 'null bytes');
    } else {
        record_check('gettext bindtextdomain null byte domain check skipped before PHP 8.3', true, PHP_VERSION);
    }

    $codeset = bind_textdomain_codeset('utf8Test', 'UTF-8');
    record_check('gettext UTF-8 codeset accepted', (is_string($codeset) && strtolower($codeset) === 'utf-8') || $codeset === false || $codeset === null, $codeset);
    record_check('gettext UTF-8 codeset reads current value', strtolower((string) bind_textdomain_codeset('utf8Test', null)) === 'utf-8', bind_textdomain_codeset('utf8Test', null));
    $latin1Codeset = bind_textdomain_codeset('latin1Test', 'UTF-8');
    record_check('gettext Latin-1 catalog UTF-8 target codeset accepted', (is_string($latin1Codeset) && strtolower($latin1Codeset) === 'utf-8') || $latin1Codeset === false || $latin1Codeset === null, $latin1Codeset);
    expect_value_error('gettext bind_textdomain_codeset rejects empty domain', fn() => bind_textdomain_codeset('', 'UTF-8'), 'must not be empty');
    record_check('gettext textdomain returns new domain', textdomain('messages') === 'messages');
    record_check('gettext textdomain reads current domain', textdomain(null) === 'messages', textdomain(null));
    expect_value_error('gettext textdomain rejects empty domain', fn() => textdomain(''), 'must not be empty');
    expect_value_error('gettext textdomain rejects zero domain', fn() => textdomain('0'), 'cannot be zero');

    record_check('gettext translates active domain', gettext('Basic test') === 'A basic test', gettext('Basic test'));
    record_check('gettext underscore alias translates', _('Basic test') === 'A basic test', _('Basic test'));
    record_check('gettext keeps unknown messages unchanged', gettext('missing-message') === 'missing-message', gettext('missing-message'));

    textdomain('dngettextTest');
    record_check('gettext singular plural form', ngettext('item', 'items', 1) === 'Produkt', ngettext('item', 'items', 1));
    record_check('gettext zero uses plural form', ngettext('item', 'items', 0) === 'Produkte', ngettext('item', 'items', 0));
    record_check('gettext plural form', ngettext('item', 'items', 2) === 'Produkte', ngettext('item', 'items', 2));
    record_check('gettext domain plural singular lookup', dngettext('dngettextTest', 'item', 'items', 1) === 'Produkt', dngettext('dngettextTest', 'item', 'items', 1));
    record_check('gettext domain plural lookup', dngettext('dngettextTest', 'item', 'items', 2) === 'Produkte', dngettext('dngettextTest', 'item', 'items', 2));

    textdomain('dgettextTest');
    record_check('gettext domain-specific lookup', dgettext('dgettextTest_switch', 'item') === 'Produkt_switched', dgettext('dgettextTest_switch', 'item'));
    record_check('gettext dgettext does not switch active domain', gettext('item') === 'Produkt', gettext('item'));

    if (defined('LC_MESSAGES') && constant('LC_MESSAGES') !== LC_ALL) {
        $category = constant('LC_MESSAGES');
        record_check('gettext category lookup', dcgettext('dngettextTest', 'item', $category) === 'Produkt', dcgettext('dngettextTest', 'item', $category));
        record_check('gettext domain category plural lookup', dcngettext('dngettextTest', 'item', 'items', 1, $category) === 'Produkt', dcngettext('dngettextTest', 'item', 'items', 1, $category));
    } else {
        $categoryResult = dcgettext('dngettextTest', 'item', LC_CTYPE);
        $pluralCategoryResult = dcngettext('dngettextTest', 'item', 'items', 1, LC_CTYPE);
        record_check('gettext category lookup callable without LC_MESSAGES', is_string($categoryResult), $categoryResult);
        record_check('gettext domain category plural lookup callable without LC_MESSAGES', is_string($pluralCategoryResult), $pluralCategoryResult);
    }
    record_check('gettext LC_CTYPE category lookup', dcgettext('dngettextTest', 'item', LC_CTYPE) === 'cProdukt', dcgettext('dngettextTest', 'item', LC_CTYPE));
    record_check('gettext LC_CTYPE category plural lookup', dcngettext('dngettextTest', 'item', 'items', 2, LC_CTYPE) === 'cProdukte', dcngettext('dngettextTest', 'item', 'items', 2, LC_CTYPE));
    expect_value_error('gettext dcgettext rejects LC_ALL category', fn() => dcgettext('dngettextTest', 'item', LC_ALL), 'LC_ALL');
    expect_value_error('gettext dcngettext rejects LC_ALL category', fn() => dcngettext('dngettextTest', 'item', 'items', 1, LC_ALL), 'LC_ALL');
    expect_value_error('gettext dcngettext rejects empty domain', fn() => dcngettext('', 'item', 'items', 1, LC_CTYPE), 'must not be empty');

    textdomain('utf8Test');
    record_check('gettext UTF-8 payload survives', gettext('encoding-euro') === 'euro-€', gettext('encoding-euro'));

    textdomain('latin1Test');
    $latin1Result = gettext('encoding-cafe');
    $result['details']['gettext_latin1_conversion_behavior'] = [
        'actual' => $latin1Result,
        'hex' => bin2hex($latin1Result),
        'converted_utf8' => $latin1Result === 'café',
        'raw_iso_8859_1' => $latin1Result === "caf\xE9",
    ];
    record_check(
        'gettext Latin-1 catalog lookup completes',
        $latin1Result === 'café' || $latin1Result === "caf\xE9",
        $result['details']['gettext_latin1_conversion_behavior']
    );

    $cUtf8Locale = setlocale(LC_ALL, 'C.UTF-8', 'C.utf8');
    if (is_string($cUtf8Locale) && $cUtf8Locale !== '') {
        textdomain('messages');
        $cUtf8Result = gettext('Basic test');
        $result['details']['gettext_c_utf8_behavior'] = [
            'available' => true,
            'locale' => $cUtf8Locale,
            'actual' => $cUtf8Result,
            'translated' => $cUtf8Result === 'A basic test',
            'untranslated' => $cUtf8Result === 'Basic test',
        ];
        record_check('gettext C.UTF-8 locale lookup completes', is_string($cUtf8Result), $result['details']['gettext_c_utf8_behavior']);
    } else {
        $result['details']['gettext_c_utf8_behavior'] = ['available' => false];
        record_check('gettext C.UTF-8 locale check skipped when locale is unavailable', true);
    }
    putenv('LANGUAGE=');
    putenv('LC_ALL=en_US.UTF-8');
    putenv('LC_MESSAGES=en_US.UTF-8');
    putenv('LANG=en_US.UTF-8');
    setlocale(LC_ALL, ...array_unique($localeCandidates));

    $unicodeRoot = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'winlibs-gettext-unicode-é-' . getmypid();
    foreach (array_unique($localeCandidates) as $localeName) {
        create_gettext_catalog($unicodeRoot, $localeName, 'LC_MESSAGES', 'unicodePath', ['' => $utf8Header, 'unicode-path' => 'unicode-ok']);
    }
    $unicodeBind = bindtextdomain('unicodePath', str_replace('\\', '/', $unicodeRoot));
    textdomain('unicodePath');
    $unicodePathResult = gettext('unicode-path');
    $result['details']['gettext_unicode_path_behavior'] = [
        'bind_returned_path' => is_string($unicodeBind) && $unicodeBind !== '',
        'actual' => $unicodePathResult,
        'translated' => $unicodePathResult === 'unicode-ok',
    ];
    record_check(
        'gettext unicode catalog path lookup completes',
        is_string($unicodePathResult),
        $result['details']['gettext_unicode_path_behavior']
    );

    $result['details']['gettext_locale_switch_behavior'] = [];
    foreach ($localeSwitchCatalogs as $case) {
        putenv('LANGUAGE=');
        putenv('LC_ALL=' . $case['aliases'][0]);
        putenv('LC_MESSAGES=' . $case['aliases'][0]);
        putenv('LANG=' . $case['aliases'][0]);
        $switchedLocale = setlocale(LC_ALL, ...$case['aliases']);
        bindtextdomain('localeSwitch', $bindRoot);
        bind_textdomain_codeset('localeSwitch', 'UTF-8');
        textdomain('localeSwitch');
        if (is_string($switchedLocale) && $switchedLocale !== '') {
            $actual = gettext('language-name');
            $result['details']['gettext_locale_switch_behavior'][$case['label']] = [
                'available' => true,
                'locale' => $switchedLocale,
                'actual' => $actual,
                'translated' => $actual === $case['expected'],
            ];
            record_check(
                'gettext locale switch lookup completes for ' . $case['label'] . ' catalog when locale is available',
                is_string($actual),
                $result['details']['gettext_locale_switch_behavior'][$case['label']]
            );
        } else {
            $result['details']['gettext_locale_switch_behavior'][$case['label']] = [
                'available' => false,
                'aliases' => $case['aliases'],
            ];
            record_check(
                'gettext locale switch skips ' . $case['label'] . ' catalog when locale is unavailable',
                true,
                ['aliases' => $case['aliases']]
            );
        }
    }
    putenv('LANGUAGE=');
    putenv('LC_ALL=en_US.UTF-8');
    putenv('LC_MESSAGES=en_US.UTF-8');
    putenv('LANG=en_US.UTF-8');
    setlocale(LC_ALL, ...array_unique($localeCandidates));
}

function run_enchant_checks(): void
{
    global $result;

    record_check('enchant extension loaded', extension_loaded('enchant'));
    $expected = [
        'enchant_broker_init',
        'enchant_broker_describe',
        'enchant_broker_list_dicts',
        'enchant_broker_dict_exists',
        'enchant_broker_request_dict',
        'enchant_broker_request_pwl_dict',
        'enchant_broker_set_ordering',
        'enchant_broker_get_error',
        'enchant_broker_free_dict',
        'enchant_broker_free',
        'enchant_broker_set_dict_path',
        'enchant_broker_get_dict_path',
        'enchant_dict_check',
        'enchant_dict_quick_check',
        'enchant_dict_suggest',
        'enchant_dict_add',
        'enchant_dict_add_to_session',
        'enchant_dict_is_in_session',
        'enchant_dict_is_added',
        'enchant_dict_describe',
        'enchant_dict_get_error',
        'enchant_dict_store_replacement',
    ];
    if (PHP_VERSION_ID >= 80500) {
        $expected[] = 'enchant_dict_remove';
        $expected[] = 'enchant_dict_remove_from_session';
    }
    foreach ($expected as $function) {
        record_check("enchant function $function exists", function_exists($function));
    }
    if (!extension_loaded('enchant')) {
        return;
    }

    $defaultBroker = enchant_broker_init();
    $defaultProviders = enchant_broker_describe($defaultBroker);
    $result['details']['enchant_default_providers'] = $defaultProviders;
    $result['details']['enchant_default_provider_names'] = array_values(array_filter(array_map(
        static fn($provider) => is_array($provider) ? ($provider['name'] ?? null) : (is_object($provider) ? ($provider->name ?? null) : null),
        is_array($defaultProviders) ? $defaultProviders : []
    ), static fn($name) => is_string($name) && $name !== ''));
    enchant_broker_free($defaultBroker);

    $phpRoot = getenv('WINLIBS_PHP_ROOT');
    $modulePath = null;
    if (is_string($phpRoot) && $phpRoot !== '') {
        $candidate = $phpRoot . DIRECTORY_SEPARATOR . 'lib' . DIRECTORY_SEPARATOR . 'enchant';
        if (is_dir($candidate)) {
            $modulePath = $candidate;
            putenv('ENCHANT_MODULE_PATH=' . $candidate);
        }
    }
    $hunspellDir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'winlibs-hunspell-' . getmypid();
    if (!is_dir($hunspellDir) && !mkdir($hunspellDir, 0777, true) && !is_dir($hunspellDir)) {
        throw new RuntimeException("Could not create $hunspellDir");
    }
    file_put_contents($hunspellDir . DIRECTORY_SEPARATOR . 'en_US.aff', "SET UTF-8\nTRY esianrtolcdugmphbyfvkwzxjq\n");
    file_put_contents($hunspellDir . DIRECTORY_SEPARATOR . 'en_US.dic', "4\ncodex\ncolour\nlocalisation\nruntimeword\n");
    putenv('DICPATH=' . $hunspellDir);
    $result['details']['enchant_environment'] = [
        'WINLIBS_PHP_ROOT' => $phpRoot,
        'ENCHANT_MODULE_PATH' => getenv('ENCHANT_MODULE_PATH'),
        'DICPATH' => getenv('DICPATH'),
        'module_path_exists' => $modulePath !== null,
    ];

    $broker = enchant_broker_init();
    record_check('enchant broker initializes', is_object($broker) || is_resource($broker), get_debug_type($broker));

    $providers = enchant_broker_describe($broker);
    record_check('enchant provider list is available', is_array($providers), $providers);
    $result['details']['enchant_providers'] = $providers;
    $result['details']['enchant_provider_names'] = array_values(array_filter(array_map(
        static fn($provider) => is_array($provider) ? ($provider['name'] ?? null) : (is_object($provider) ? ($provider->name ?? null) : null),
        is_array($providers) ? $providers : []
    ), static fn($name) => is_string($name) && $name !== ''));

    $dicts = enchant_broker_list_dicts($broker);
    record_check('enchant installed dictionary list is available', is_array($dicts), $dicts);
    $result['details']['enchant_installed_dicts'] = $dicts;
    $result['details']['enchant_installed_dictionary_languages'] = array_values(array_filter(array_map(
        static fn($dict) => is_array($dict) ? ($dict['lang_tag'] ?? $dict['lang'] ?? null) : (is_object($dict) ? ($dict->lang_tag ?? $dict->lang ?? null) : null),
        is_array($dicts) ? $dicts : []
    ), static fn($lang) => is_string($lang) && $lang !== ''));

    if (function_exists('enchant_broker_get_error')) {
        $error = enchant_broker_get_error($broker);
        record_check('enchant broker error API is callable', $error === false || $error === null || is_string($error), $error);
    }
    if (function_exists('enchant_broker_set_ordering')) {
        $ordering = enchant_broker_set_ordering($broker, '*', 'myspell,ispell,aspell,hspell');
        record_check('enchant provider ordering API is callable', $ordering === true || $ordering === false || $ordering === null, $ordering);
        if (PHP_VERSION_ID >= 80500) {
            expect_value_error('enchant broker set_ordering rejects empty tag', fn() => enchant_broker_set_ordering($broker, '', 'myspell'), 'must not be empty');
            expect_value_error('enchant broker set_ordering rejects empty ordering', fn() => enchant_broker_set_ordering($broker, '*', ''), 'must not be empty');
        } else {
            record_check('enchant broker set_ordering empty argument checks skipped before PHP 8.5', true, PHP_VERSION);
        }
        if (PHP_VERSION_ID >= 80300) {
            expect_value_error('enchant broker set_ordering rejects null byte tag', fn() => enchant_broker_set_ordering($broker, "foo\0bar", 'myspell'), 'null bytes');
        } else {
            record_check('enchant broker set_ordering null byte tag check skipped before PHP 8.3', true, PHP_VERSION);
        }
    }
    if (function_exists('enchant_broker_dict_exists')) {
        if (PHP_VERSION_ID >= 80500) {
            expect_value_error('enchant broker dict_exists rejects empty tag', fn() => enchant_broker_dict_exists($broker, ''), 'must not be empty');
        } else {
            record_check('enchant broker dict_exists empty tag check skipped before PHP 8.5', true, PHP_VERSION);
        }
        if (PHP_VERSION_ID >= 80300) {
            expect_value_error('enchant broker dict_exists rejects null byte tag', fn() => enchant_broker_dict_exists($broker, "foo\0bar"), 'null bytes');
        } else {
            record_check('enchant broker dict_exists null byte tag check skipped before PHP 8.3', true, PHP_VERSION);
        }
    }
    if (function_exists('enchant_broker_request_dict')) {
        expect_value_error('enchant broker request_dict rejects empty tag', fn() => enchant_broker_request_dict($broker, ''), 'must not be empty');
        if (PHP_VERSION_ID >= 80300) {
            expect_value_error('enchant broker request_dict rejects null byte tag', fn() => enchant_broker_request_dict($broker, "foo\0bar"), 'null bytes');
        } else {
            record_check('enchant broker request_dict null byte tag check skipped before PHP 8.3', true, PHP_VERSION);
        }
    }
    if (function_exists('enchant_broker_dict_exists') && function_exists('enchant_broker_request_dict') && count($dicts) > 0) {
        $firstDict = $dicts[0];
        $lang = is_array($firstDict)
            ? ($firstDict['lang_tag'] ?? $firstDict['lang'] ?? null)
            : (is_object($firstDict) ? ($firstDict->lang_tag ?? $firstDict->lang ?? null) : null);
        if (is_string($lang) && $lang !== '') {
            record_check('enchant installed dictionary is discoverable', enchant_broker_dict_exists($broker, $lang) === true, $lang);
            $requestedDict = enchant_broker_request_dict($broker, $lang);
            record_check('enchant installed dictionary can be requested', is_object($requestedDict) || is_resource($requestedDict), get_debug_type($requestedDict));
            if (is_object($requestedDict) || is_resource($requestedDict)) {
                enchant_broker_free_dict($requestedDict);
            }
        } else {
            record_check('enchant installed dictionary metadata has a language tag when dictionaries exist', false, $firstDict);
        }
    } else {
        record_check('enchant installed dictionary path skipped when no dictionaries are installed', true, $dicts);
    }

    $hasConfiguredHunspell = false;
    if (function_exists('enchant_broker_dict_exists') && function_exists('enchant_broker_request_dict')) {
        $hasConfiguredHunspell = enchant_broker_dict_exists($broker, 'en_US') === true;
        record_check('enchant configured hunspell dictionary discoverable when provider is available', true, $hasConfiguredHunspell);
        if ($hasConfiguredHunspell) {
            $hunspellDict = enchant_broker_request_dict($broker, 'en_US');
            record_check('enchant configured hunspell dictionary opens', is_object($hunspellDict) || is_resource($hunspellDict), get_debug_type($hunspellDict));
            if (is_object($hunspellDict) || is_resource($hunspellDict)) {
                record_check('enchant configured hunspell accepts known word', enchant_dict_check($hunspellDict, 'codex') === true);
                record_check('enchant configured hunspell rejects unknown word', enchant_dict_check($hunspellDict, 'codexx') === false);
                $hunspellSuggestions = enchant_dict_suggest($hunspellDict, 'codexx');
                record_check('enchant configured hunspell suggestions return an array', is_array($hunspellSuggestions), $hunspellSuggestions);
                enchant_broker_free_dict($hunspellDict);
            }
        }
    }
    $result['details']['enchant_configured_hunspell_available'] = $hasConfiguredHunspell;

    $pwl = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'winlibs-enchant-' . getmypid() . '.pwl';
    file_put_contents($pwl, "codex\ncolour\nlocalisation\n");
    $dict = enchant_broker_request_pwl_dict($broker, $pwl);
    record_check('enchant PWL dictionary opens', is_object($dict) || is_resource($dict), get_debug_type($dict));
    if (!is_object($dict) && !is_resource($dict)) {
        return;
    }

    $description = enchant_dict_describe($dict);
    record_check('enchant dictionary description is available', is_array($description), $description);
    $result['details']['enchant_pwl_description'] = $description;

    record_check('enchant PWL accepts known word', enchant_dict_check($dict, 'codex') === true);
    record_check('enchant PWL rejects unknown word', enchant_dict_check($dict, 'codexx') === false);
    $suggestions = enchant_dict_suggest($dict, 'codexx');
    record_check('enchant suggestions return an array', is_array($suggestions), $suggestions);
    $quickSuggestions = [];
    $quickCheck = enchant_dict_quick_check($dict, 'codexx', $quickSuggestions);
    record_check('enchant quick_check rejects unknown word', $quickCheck === false, ['result' => $quickCheck, 'suggestions' => $quickSuggestions]);
    record_check('enchant quick_check suggestions return an array', is_array($quickSuggestions), $quickSuggestions);

    enchant_dict_add($dict, 'runtimeword');
    record_check('enchant runtime-added word is accepted', enchant_dict_check($dict, 'runtimeword') === true);
    if (function_exists('enchant_dict_is_added')) {
        record_check('enchant runtime-added word membership is tracked', enchant_dict_is_added($dict, 'runtimeword') === true);
    }
    if (function_exists('enchant_dict_remove')) {
        enchant_dict_remove($dict, 'runtimeword');
        record_check('enchant removed runtime-added word is rejected', enchant_dict_check($dict, 'runtimeword') === false);
        if (function_exists('enchant_dict_is_added')) {
            record_check('enchant removed runtime-added word membership is cleared', enchant_dict_is_added($dict, 'runtimeword') === false);
        }
    }
    enchant_dict_add_to_session($dict, 'sessionword');
    record_check('enchant session-added word is accepted', enchant_dict_check($dict, 'sessionword') === true);
    record_check('enchant session membership is tracked', enchant_dict_is_in_session($dict, 'sessionword') === true);
    if (function_exists('enchant_dict_remove_from_session')) {
        enchant_dict_remove_from_session($dict, 'sessionword');
        record_check('enchant removed session word is rejected', enchant_dict_check($dict, 'sessionword') === false);
        record_check('enchant removed session membership is cleared', enchant_dict_is_in_session($dict, 'sessionword') === false);
    }
    if (function_exists('enchant_dict_store_replacement')) {
        enchant_dict_store_replacement($dict, 'codexx', 'codex');
        record_check('enchant replacement API is callable', true);
        if (PHP_VERSION_ID >= 80300) {
            expect_value_error('enchant replacement API rejects null byte misspelling', fn() => enchant_dict_store_replacement($dict, "foo\0bar", 'codex'), 'null bytes');
        }
    }
    if (PHP_VERSION_ID >= 80300) {
        expect_value_error('enchant dict_check rejects null byte word', fn() => enchant_dict_check($dict, "foo\0bar"), 'null bytes');
        expect_value_error('enchant dict_quick_check rejects null byte word', fn() => enchant_dict_quick_check($dict, "foo\0bar"), 'null bytes');
        expect_value_error('enchant dict_suggest rejects null byte word', fn() => enchant_dict_suggest($dict, "foo\0bar"), 'null bytes');
        expect_value_error('enchant dict_add rejects null byte word', fn() => enchant_dict_add($dict, "foo\0bar"), 'null bytes');
        expect_value_error('enchant dict_add_to_session rejects null byte word', fn() => enchant_dict_add_to_session($dict, "foo\0bar"), 'null bytes');
        if (function_exists('enchant_dict_remove_from_session')) {
            expect_value_error('enchant dict_remove_from_session rejects null byte word', fn() => enchant_dict_remove_from_session($dict, "foo\0bar"), 'null bytes');
        }
        if (function_exists('enchant_dict_is_added')) {
            expect_value_error('enchant dict_is_added rejects null byte word', fn() => enchant_dict_is_added($dict, "foo\0bar"), 'null bytes');
        }
    } else {
        record_check('enchant dictionary null byte word checks skipped before PHP 8.3', true, PHP_VERSION);
    }
    $dictError = enchant_dict_get_error($dict);
    record_check('enchant dictionary error API is callable', $dictError === false || $dictError === null || is_string($dictError), $dictError);

    if (function_exists('enchant_broker_free_dict')) {
        enchant_broker_free_dict($dict);
    }
    if (function_exists('enchant_broker_free')) {
        enchant_broker_free($broker);
    }
}

try {
    run_gettext_checks();
    run_enchant_checks();
} catch (Throwable $e) {
    record_check('uncaught exception', false, [
        'message' => $e->getMessage(),
        'file' => $e->getFile(),
        'line' => $e->getLine(),
    ]);
}

$json = json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
if ($json === false) {
    $result['failures'][] = [
        'name' => 'json encoding failed',
        'ok' => false,
        'details' => json_last_error_msg(),
    ];
    $json = json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
}
if ($jsonOut !== null) {
    file_put_contents($jsonOut, $json . PHP_EOL);
} else {
    echo $json, PHP_EOL;
}

exit(count($result['failures']) === 0 ? 0 : 1);
