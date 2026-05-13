<?php

declare(strict_types=1);

#[Attribute(Attribute::TARGET_CLASS)]
final class SuiteMarker
{
    public function __construct(public string $name)
    {
    }
}

#[SuiteMarker('functional')]
final class MarkedFixture
{
}

enum SuiteState: string
{
    case Ready = 'ready';
}

readonly class ReadonlyFixture
{
    public function __construct(public string $value)
    {
    }
}

final class FunctionalSuite
{
    /** @var list<array<string, mixed>> */
    private array $cases = [];

    /** @var array<string, mixed> */
    private array $features = [];

    public function __construct(
        private readonly string $profile,
        private readonly string $expectedPhp,
        private readonly string $expectedArch,
        private readonly string $expectedTs,
        private readonly ?string $requiredOnig,
        private readonly string $reportPath
    ) {
    }

    public function run(): int
    {
        $this->coreRuntimeTests();
        $this->extensionTests();
        $this->mbstringOnigurumaTests();
        $this->writeReport();

        $failures = array_filter($this->cases, static fn (array $case): bool => $case['status'] === 'fail');
        return $failures ? 1 : 0;
    }

    private function addCase(string $area, string $name, callable $callback, bool $compare = true): void
    {
        try {
            $details = $callback();
            $this->cases[] = [
                'area' => $area,
                'name' => $name,
                'status' => 'pass',
                'compare' => $compare,
                'details' => $details,
            ];
        } catch (Throwable $throwable) {
            $this->cases[] = [
                'area' => $area,
                'name' => $name,
                'status' => 'fail',
                'compare' => $compare,
                'details' => [
                    'message' => $throwable->getMessage(),
                    'class' => $throwable::class,
                ],
            ];
        }
    }

    private function ensure(bool $condition, string $message): void
    {
        if (!$condition) {
            throw new RuntimeException($message);
        }
    }

    /**
     * @return array{result: bool, matches: array<int|string, mixed>, warnings: list<string>}
     */
    private function mbMatch(string $pattern, string $subject): array
    {
        $warnings = [];
        $matches = [];
        set_error_handler(static function (int $severity, string $message) use (&$warnings): bool {
            if (str_contains($message, 'deprecated since 8.6')) {
                return true;
            }
            $warnings[] = $message;
            return true;
        });
        try {
            $result = mb_ereg($pattern, $subject, $matches);
        } finally {
            restore_error_handler();
        }

        return [
            'result' => $result === true,
            'matches' => $matches,
            'warnings' => $warnings,
        ];
    }

    /**
     * @return array{result: bool, warnings: list<string>}
     */
    private function mbStartMatch(string $pattern, string $subject): array
    {
        $warnings = [];
        set_error_handler(static function (int $severity, string $message) use (&$warnings): bool {
            if (str_contains($message, 'deprecated since 8.6')) {
                return true;
            }
            $warnings[] = $message;
            return true;
        });
        try {
            $result = mb_ereg_match($pattern, $subject);
        } finally {
            restore_error_handler();
        }

        return ['result' => $result === true, 'warnings' => $warnings];
    }

    private function onigVersion(): ?string
    {
        return defined('MB_ONIGURUMA_VERSION') ? (string) constant('MB_ONIGURUMA_VERSION') : null;
    }

    private function onigAtLeast(string $minimum): bool
    {
        $version = $this->onigVersion();
        return $version !== null && version_compare($version, $minimum, '>=');
    }

    private function recordFeature(string $name, mixed $value): void
    {
        $this->features[$name] = $value;
    }

    /**
     * @return list<string>
     */
    private function requiredExtensionInventory(): array
    {
        $extensions = [
            'Core',
            'PDO',
            'Phar',
            'Reflection',
            'SPL',
            'SimpleXML',
            'Zend OPcache',
            'bcmath',
            'calendar',
            'ctype',
            'curl',
            'date',
            'dom',
            'exif',
            'fileinfo',
            'filter',
            'gd',
            'hash',
            'iconv',
            'intl',
            'json',
            'libxml',
            'mbstring',
            'mysqlnd',
            'openssl',
            'pcre',
            'pdo_sqlite',
            'random',
            'readline',
            'session',
            'sodium',
            'sqlite3',
            'standard',
            'tokenizer',
            'xml',
            'xmlreader',
            'xmlwriter',
            'zip',
            'zlib',
        ];

        if (version_compare($this->expectedPhp, '8.5', '>=')) {
            $extensions[] = 'lexbor';
            $extensions[] = 'uri';
        }

        sort($extensions);
        return $extensions;
    }

    /**
     * @return array<string, string>
     */
    private function loadedExtensionMap(): array
    {
        $map = [];
        foreach (get_loaded_extensions() as $extension) {
            $map[strtolower($extension)] = $extension;
        }
        ksort($map);
        return $map;
    }

    private function versionedOnigFeature(string $name, string $minimum, callable $probe): void
    {
        $this->addCase('oniguruma', $name, function () use ($name, $minimum, $probe): array {
            $supported = $this->onigAtLeast($minimum);
            $observed = $probe();
            $ok = (bool) ($observed['ok'] ?? false);
            $this->recordFeature($name, $ok);

            if ($supported) {
                $this->ensure($ok, "Expected $name for Oniguruma >= $minimum");
            }

            return [
                'minimum' => $minimum,
                'oniguruma' => $this->onigVersion(),
                'required_by_version' => $supported,
                'observed' => $observed,
            ];
        }, false);
    }

    /**
     * @param list<int> $positiveCodepoints
     * @param list<int> $negativeCodepoints
     * @return array<string, mixed>
     */
    private function probeUnicodePropertyCorpus(string $property, array $positiveCodepoints, array $negativeCodepoints): array
    {
        $positive = [];
        $negative = [];
        $ok = true;

        foreach ($positiveCodepoints as $codepoint) {
            $subject = mb_chr($codepoint, 'UTF-8');
            $match = $this->mbMatch('\A\p{' . $property . '}\z', $subject);
            $passed = $match['result'] && ($match['matches'][0] ?? null) === $subject;
            $ok = $ok && $passed;
            $positive[] = [
                'codepoint' => sprintf('U+%04X', $codepoint),
                'passed' => $passed,
                'match' => $match,
            ];
        }

        foreach ($negativeCodepoints as $codepoint) {
            $subject = mb_chr($codepoint, 'UTF-8');
            $match = $this->mbMatch('\A\p{' . $property . '}\z', $subject);
            $passed = !$match['result'];
            $ok = $ok && $passed;
            $negative[] = [
                'codepoint' => sprintf('U+%04X', $codepoint),
                'passed' => $passed,
                'match' => $match,
            ];
        }

        return [
            'ok' => $ok,
            'property' => $property,
            'positive_count' => count($positive),
            'negative_count' => count($negative),
            'positive' => $positive,
            'negative' => $negative,
        ];
    }

    private function coreRuntimeTests(): void
    {
        $this->addCase('runtime', 'version_arch_thread_safety', function (): array {
            $this->ensure(str_starts_with(PHP_VERSION, $this->expectedPhp . '.'), 'Unexpected PHP version: ' . PHP_VERSION);
            $actualArch = PHP_INT_SIZE === 8 ? 'x64' : 'x86';
            $actualTs = PHP_ZTS ? 'ts' : 'nts';
            $this->ensure($actualArch === $this->expectedArch, "Expected $this->expectedArch, got $actualArch");
            $this->ensure($actualTs === $this->expectedTs, "Expected $this->expectedTs, got $actualTs");
            return [
                'php_version' => PHP_VERSION,
                'arch' => $actualArch,
                'ts' => $actualTs,
                'sapi' => PHP_SAPI,
            ];
        });

        $this->addCase('runtime', 'json_arrays_generators', function (): array {
            $payload = [
                'state' => SuiteState::Ready->value,
                'values' => iterator_to_array((function (): Generator {
                    yield 'alpha' => 1;
                    yield 'beta' => 2;
                })()),
            ];
            $json = json_encode($payload, JSON_THROW_ON_ERROR);
            $decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
            $this->ensure($decoded['values']['alpha'] === 1 && $decoded['values']['beta'] === 2, 'JSON/generator round-trip failed');
            return $decoded;
        });

        $this->addCase('runtime', 'attributes_reflection_readonly', function (): array {
            $reflection = new ReflectionClass(MarkedFixture::class);
            $attributes = $reflection->getAttributes(SuiteMarker::class);
            $readonly = new ReadonlyFixture('locked');
            $this->ensure(count($attributes) === 1, 'Attribute was not reflected');
            $this->ensure($attributes[0]->newInstance()->name === 'functional', 'Attribute payload mismatch');
            $this->ensure($readonly->value === 'locked', 'Readonly property mismatch');
            return ['attribute' => $attributes[0]->getName(), 'readonly' => $readonly->value];
        });

        $this->addCase('runtime', 'fibers_exceptions_random', function (): array {
            $fiber = new Fiber(static function (): string {
                $value = Fiber::suspend('paused');
                return 'done-' . $value;
            });
            $this->ensure($fiber->start() === 'paused', 'Fiber did not suspend correctly');
            $fiber->resume('ok');
            $this->ensure($fiber->isTerminated() && $fiber->getReturn() === 'done-ok', 'Fiber did not resume correctly');
            $random = random_int(1000, 9999);
            try {
                throw new LogicException('expected');
            } catch (LogicException $exception) {
                $this->ensure($exception->getMessage() === 'expected', 'Exception handling failed');
            }
            return ['random_range' => $random >= 1000 && $random <= 9999];
        });

        $this->addCase('runtime', 'filesystem_streams_datetime', function (): array {
            $file = tempnam(sys_get_temp_dir(), 'php-functional-');
            $this->ensure($file !== false, 'tempnam failed');
            file_put_contents($file, "alpha\nbeta\n");
            $content = file_get_contents($file);
            unlink($file);
            $date = new DateTimeImmutable('2024-09-11T00:00:00Z');
            $this->ensure($content === "alpha\nbeta\n", 'File round-trip failed');
            $this->ensure($date->format('Y-m-d') === '2024-09-11', 'DateTime formatting failed');
            return ['bytes' => strlen($content), 'date' => $date->format(DateTimeInterface::ATOM)];
        });
    }

    private function extensionTests(): void
    {
        $this->addCase('extensions', 'required_extensions_loaded', function (): array {
            foreach (['Core', 'date', 'filter', 'hash', 'json', 'mbstring', 'pcre', 'SPL', 'standard'] as $extension) {
                $this->ensure(isset($this->loadedExtensionMap()[strtolower($extension)]), "Required extension not loaded: $extension");
            }
            return ['loaded' => get_loaded_extensions()];
        });

        $this->addCase('extensions', 'required_extension_inventory', function (): array {
            $expected = $this->requiredExtensionInventory();
            $loadedMap = $this->loadedExtensionMap();
            $missing = [];

            foreach ($expected as $extension) {
                if (!isset($loadedMap[strtolower($extension)])) {
                    $missing[] = $extension;
                }
            }

            $this->ensure($missing === [], 'Missing required Windows PHP extensions: ' . implode(', ', $missing));

            return [
                'expected' => $expected,
                'loaded' => array_values($loadedMap),
                'missing' => $missing,
            ];
        });

        $this->addCase('extensions', 'hash_openssl_crypto', function (): array {
            $hmac = hash_hmac('sha256', 'payload', 'secret');
            $this->ensure($hmac === 'b82fcb791acec57859b989b430a826488ce2e479fdf92326bd0a2e8375a42ba4', 'hash_hmac mismatch');
            if (extension_loaded('openssl')) {
                $bytes = openssl_random_pseudo_bytes(16);
                $this->ensure(is_string($bytes) && strlen($bytes) === 16, 'openssl_random_pseudo_bytes failed');
            }
            return ['openssl' => extension_loaded('openssl')];
        });

        $this->addCase('extensions', 'required_extensions_functional', function (): array {
            $details = [
                'pdo_sqlite' => extension_loaded('pdo_sqlite'),
                'zip' => extension_loaded('zip'),
                'intl' => extension_loaded('intl'),
                'curl' => extension_loaded('curl'),
                'sodium' => extension_loaded('sodium'),
                'gd' => extension_loaded('gd'),
            ];

            foreach ($details as $extension => $loaded) {
                $this->ensure($loaded, "Functional extension missing: $extension");
            }

            $pdo = new PDO('sqlite::memory:');
            $pdo->exec('CREATE TABLE t (v TEXT)');
            $pdo->exec("INSERT INTO t VALUES ('ok')");
            $this->ensure($pdo->query('SELECT v FROM t')->fetchColumn() === 'ok', 'SQLite query failed');

            $zipPath = tempnam(sys_get_temp_dir(), 'php-functional-zip-');
            $zip = new ZipArchive();
            $this->ensure($zip->open($zipPath, ZipArchive::OVERWRITE) === true, 'Zip open failed');
            $zip->addFromString('payload.txt', 'zip-ok');
            $zip->close();
            $zip->open($zipPath);
            $this->ensure($zip->getFromName('payload.txt') === 'zip-ok', 'Zip read failed');
            $zip->close();
            unlink($zipPath);

            $formatter = new NumberFormatter('en_US', NumberFormatter::DECIMAL);
            $this->ensure($formatter->format(1234.5) === '1,234.5', 'Intl NumberFormatter failed');
            $this->ensure(is_array(curl_version()), 'curl_version failed');
            $this->ensure(strlen(sodium_crypto_generichash('payload')) === SODIUM_CRYPTO_GENERICHASH_BYTES, 'sodium hash failed');

            $image = imagecreatetruecolor(2, 2);
            $this->ensure($image instanceof GdImage, 'GD image creation failed');
            imagedestroy($image);

            return $details;
        });
    }

    private function mbstringOnigurumaTests(): void
    {
        $this->addCase('oniguruma', 'version_and_encoding', function (): array {
            $this->ensure(extension_loaded('mbstring'), 'mbstring is not loaded');
            $onig = $this->onigVersion();
            $this->ensure($onig !== null, 'MB_ONIGURUMA_VERSION is not defined');
            if ($this->requiredOnig !== null) {
                $this->ensure($onig === $this->requiredOnig, "Expected Oniguruma $this->requiredOnig, got $onig");
            }
            $this->ensure(mb_regex_encoding('UTF-8') === true, 'Failed to set mb_regex_encoding');
            return ['oniguruma' => $onig, 'regex_encoding' => mb_regex_encoding()];
        }, false);

        $this->addCase('oniguruma', 'posix_punct_ascii', function (): array {
            $match = $this->mbMatch('[[:punct:]]+', '.!"*@');
            $this->ensure($match['result'] && $match['matches'][0] === '.!"*@', 'ASCII POSIX punct failed');
            $this->ensure($match['warnings'] === [], 'Unexpected POSIX punct warnings');
            return $match;
        });

        $this->versionedOnigFeature('posix_punct_symbols', '6.9.9', function (): array {
            $subject = '$' . "\u{00A6}";
            $class = $this->mbMatch('[[:punct:]]+', $subject);
            $property = $this->mbMatch('\p{PosixPunct}+', $subject);
            return [
                'ok' => $class['result'] && ($class['matches'][0] ?? null) === $subject &&
                    $property['result'] && ($property['matches'][0] ?? null) === $subject,
                'class' => $class,
                'property' => $property,
            ];
        });

        $this->versionedOnigFeature('negative_posix_brackets', '6.9.9', function (): array {
            $notUpperHit = $this->mbMatch('[[:^upper:]]', 'a');
            $notUpperMiss = $this->mbMatch('[[:^upper:]]', 'A');
            $notLowerHit = $this->mbMatch('[[:^lower:]]', 'A');
            $notLowerMiss = $this->mbMatch('[[:^lower:]]', 'a');
            return [
                'ok' => $notUpperHit['result'] && !$notUpperMiss['result'] &&
                    $notLowerHit['result'] && !$notLowerMiss['result'],
                'cases' => compact('notUpperHit', 'notUpperMiss', 'notLowerHit', 'notLowerMiss'),
            ];
        });

        $this->versionedOnigFeature('posix_bracket_parser_edges', '6.9.9', function (): array {
            $literalColon = $this->mbMatch('[[::]]', ':');
            $literalColonTriple = $this->mbMatch('[[:::]]', ':');
            $escapedClose = $this->mbMatch('[[:\]:]]*', ':]');
            $invalidShortName = $this->mbMatch('[[:u:]]', '');
            return [
                'ok' => $literalColon['result'] && $literalColonTriple['result'] &&
                    $escapedClose['result'] && !$invalidShortName['result'] &&
                    $invalidShortName['warnings'] !== [],
                'cases' => compact('literalColon', 'literalColonTriple', 'escapedClose', 'invalidShortName'),
            ];
        });

        $this->versionedOnigFeature('unicode_15_kawi', '6.9.9', function (): array {
            $match = $this->mbMatch('\p{Kawi}', "\u{11F50}");
            return ['ok' => $match['result'], 'match' => $match];
        });

        $this->versionedOnigFeature('unicode_15_nag_mundari', '6.9.9', function (): array {
            $match = $this->mbMatch('\p{Nag_Mundari}', "\u{1E4D0}");
            return ['ok' => $match['result'], 'match' => $match];
        });

        $this->versionedOnigFeature('unicode_16_garay', '6.9.10', function (): array {
            $match = $this->mbMatch('\p{Garay}', "\u{10D40}");
            return ['ok' => $match['result'], 'match' => $match];
        });

        $this->versionedOnigFeature('unicode_15_kawi_corpus', '6.9.9', function (): array {
            return $this->probeUnicodePropertyCorpus('Kawi', [0x11F00, 0x11F12, 0x11F3E, 0x11F50], [0x11EFF, 0x11F5B, 0x0041]);
        });

        $this->versionedOnigFeature('unicode_15_nag_mundari_corpus', '6.9.9', function (): array {
            return $this->probeUnicodePropertyCorpus('Nag_Mundari', [0x1E4D0, 0x1E4EA, 0x1E4F0, 0x1E4F9], [0x1E4CF, 0x1E4FA, 0x0041]);
        });

        $this->versionedOnigFeature('unicode_16_garay_corpus', '6.9.10', function (): array {
            return $this->probeUnicodePropertyCorpus('Garay', [0x10D40, 0x10D51, 0x10D69, 0x10D85], [0x10D3F, 0x10D86, 0x0041]);
        });

        $this->versionedOnigFeature('posix_punct_generated_corpus', '6.9.9', function (): array {
            $positiveCodepoints = [
                0x0021,
                0x0024,
                0x002B,
                0x003C,
                0x003D,
                0x003E,
                0x005E,
                0x005F,
                0x0060,
                0x007C,
                0x007E,
                0x00A2,
                0x00A6,
                0x20AC,
            ];
            $negativeCodepoints = [0x0020, 0x0030, 0x0041, 0x3042];
            $patterns = ['[[:punct:]]', '\p{PosixPunct}'];
            $cases = [];
            $ok = true;

            foreach ($patterns as $pattern) {
                foreach ($positiveCodepoints as $codepoint) {
                    $subject = mb_chr($codepoint, 'UTF-8');
                    $match = $this->mbMatch('\A' . $pattern . '\z', $subject);
                    $passed = $match['result'] && ($match['matches'][0] ?? null) === $subject;
                    $ok = $ok && $passed;
                    $cases[] = [
                        'pattern' => $pattern,
                        'codepoint' => sprintf('U+%04X', $codepoint),
                        'expected' => true,
                        'passed' => $passed,
                        'match' => $match,
                    ];
                }

                foreach ($negativeCodepoints as $codepoint) {
                    $subject = mb_chr($codepoint, 'UTF-8');
                    $match = $this->mbMatch('\A' . $pattern . '\z', $subject);
                    $passed = !$match['result'];
                    $ok = $ok && $passed;
                    $cases[] = [
                        'pattern' => $pattern,
                        'codepoint' => sprintf('U+%04X', $codepoint),
                        'expected' => false,
                        'passed' => $passed,
                        'match' => $match,
                    ];
                }
            }

            return [
                'ok' => $ok,
                'positive_count' => count($positiveCodepoints),
                'negative_count' => count($negativeCodepoints),
                'pattern_count' => count($patterns),
                'cases' => $cases,
            ];
        });

        $this->versionedOnigFeature('unicode_word_ignorecase_equivalence', '6.9.9', function (): array {
            $longS = "\u{017F}";
            $wordProperty = $this->mbMatch('(?i)\p{Word}', $longS);
            $wordClass = $this->mbMatch('(?i)\w', $longS);
            $notWordProperty = $this->mbMatch('(?i)\P{Word}', $longS);
            $notWordClass = $this->mbMatch('(?i)\W', $longS);
            $bracketProperty = $this->mbMatch('(?i)[\p{Word}]', $longS);
            $bracketClass = $this->mbMatch('(?i)[\w]', $longS);
            return [
                'ok' => $wordProperty['result'] && $wordClass['result'] &&
                    !$notWordProperty['result'] && !$notWordClass['result'] &&
                    $bracketProperty['result'] && $bracketClass['result'],
                'cases' => compact('wordProperty', 'wordClass', 'notWordProperty', 'notWordClass', 'bracketProperty', 'bracketClass'),
            ];
        });

        $this->versionedOnigFeature('find_longest_all_alternatives', '6.9.9', function (): array {
            mb_regex_set_options('l');
            $first = $this->mbMatch('a{4}|a{3}|b*', 'baaaaabbb');
            $second = $this->mbMatch('a{3}|a{4}|b*', 'baaaaabbb');
            mb_regex_set_options('');
            return [
                'ok' => ($first['matches'][0] ?? null) === 'aaaa' && ($second['matches'][0] ?? null) === 'aaaa',
                'first' => $first,
                'second' => $second,
            ];
        });

        $this->versionedOnigFeature('find_longest_recursive_call_with_global_option', '6.9.10', function (): array {
            mb_regex_set_options('l');
            $short = $this->mbMatch('z|a\g<0>a', 'aazaa');
            $long = $this->mbMatch('z|a\g<0>a', 'aazaaaazaaaa');
            mb_regex_set_options('');
            return [
                'ok' => ($short['matches'][0] ?? null) === 'aazaa' &&
                    ($long['matches'][0] ?? null) === 'aaaazaaaa',
                'short' => $short,
                'long' => $long,
            ];
        });

        $this->versionedOnigFeature('inline_case_option_disable', '6.9.9', function (): array {
            $enabledThenDisabled = $this->mbMatch('(?i)a(?-i)b', 'Ab');
            $disabledRejectsUpper = $this->mbMatch('(?i)a(?-i)b', 'AB');
            $groupEnabled = $this->mbMatch('(?i:a)', 'A');
            $groupDisabled = $this->mbMatch('(?-i:a)', 'A');
            return [
                'ok' => $enabledThenDisabled['result'] && !$disabledRejectsUpper['result'] &&
                    $groupEnabled['result'] && !$groupDisabled['result'],
                'cases' => compact('enabledThenDisabled', 'disabledRejectsUpper', 'groupEnabled', 'groupDisabled'),
            ];
        });

        $this->versionedOnigFeature('bounded_quantifier_short_newline_input', '6.9.9', function (): array {
            $patterns = ['\A.*\R', '\A.{0,99}\R', '\A.*\n', '\A.{0,99}\n', '\A.*\s', '\A.{0,99}\s'];
            $results = [];
            foreach ($patterns as $pattern) {
                $results[$pattern] = $this->mbMatch($pattern, "\n");
            }
            return [
                'ok' => array_reduce($results, static fn (bool $ok, array $result): bool => $ok && $result['result'] && ($result['matches'][0] ?? null) === "\n", true),
                'cases' => $results,
            ];
        });

        $this->addCase('oniguruma', 'match_whole_string_not_php_exposed', function (): array {
            $prefixOnly = $this->mbStartMatch('abc', 'abcd');
            $notAtStart = $this->mbStartMatch('abc', 'xabc');
            $wholeWithAnchor = $this->mbStartMatch('abc\z', 'abc');
            $wholeWithAnchorMiss = $this->mbStartMatch('abc\z', 'abcd');
            $this->ensure($prefixOnly['result'] && !$notAtStart['result'] && $wholeWithAnchor['result'] && !$wholeWithAnchorMiss['result'], 'mb_ereg_match whole-string behavior changed');
            return compact('prefixOnly', 'notAtStart', 'wholeWithAnchor', 'wholeWithAnchorMiss');
        }, false);

        $this->addCase('oniguruma', 'noncapturing_group_stability', function (): array {
            $match = $this->mbMatch('(?:abc)(xyz)', 'abcxyz');
            $this->ensure($match['result'] && ($match['matches'][1] ?? null) === 'xyz' && count($match['matches']) === 2, 'Noncapturing group behavior changed');
            return $match;
        }, false);

        $this->versionedOnigFeature('retry_limit_zero_unlimited', '6.9.10', function (): array {
            $regex = 'A(B|C+)+D|AC+X';
            $subject = 'ACCCCCCCCCCCCCCCCCCCX';
            ini_set('mbstring.regex_retry_limit', '100000');
            $limited = $this->mbMatch($regex, $subject);
            ini_set('mbstring.regex_retry_limit', '0');
            $unlimited = $this->mbMatch($regex, $subject);
            return [
                'ok' => $limited['result'] === false && $unlimited['result'] === true,
                'limited' => $limited,
                'unlimited' => $unlimited,
            ];
        });

        $this->versionedOnigFeature('lookbehind_anchor_empty_match', '6.9.10', function (): array {
            $positiveX = $this->mbMatch('(?<=RMA)X', '123RMAX');
            $negativeX = $this->mbMatch('(?<!RMA)X', '123RMAX');
            $positiveDollar = $this->mbMatch('(?<=RMA)$', '123RMA');
            $negativeDollar = $this->mbMatch('(?<!RMA)$', '123RMA');
            $positiveZ = $this->mbMatch('(?<=RMA)\Z', '123RMA');
            $negativeZ = $this->mbMatch('(?<!RMA)\Z', '123RMA');
            $positivez = $this->mbMatch('(?<=RMA)\z', '123RMA');
            $negativez = $this->mbMatch('(?<!RMA)\z', '123RMA');
            return [
                'ok' => $positiveX['result'] && !$negativeX['result'] &&
                    $positiveDollar['result'] && !$negativeDollar['result'] &&
                    $positiveZ['result'] && !$negativeZ['result'] &&
                    $positivez['result'] && !$negativez['result'],
                'cases' => compact('positiveX', 'negativeX', 'positiveDollar', 'negativeDollar', 'positiveZ', 'negativeZ', 'positivez', 'negativez'),
            ];
        });

        $this->versionedOnigFeature('literal_escaped_braces', '6.9.10', function (): array {
            $plain = $this->mbMatch('\{1\}', '{1}');
            $anchored = $this->mbMatch('^\{1\}', '{1}');
            $grouped = $this->mbMatch('(\{1\})', '{1}');
            return [
                'ok' => $plain['result'] && $anchored['result'] && $grouped['result'],
                'plain' => $plain,
                'anchored' => $anchored,
                'grouped' => $grouped,
            ];
        });

        $this->addCase('oniguruma', 'bre_anchor_edges', function (): array {
            $results = [];
            foreach ([['ab', '\(^ab\)'], ['ab', '\(ab$\)'], ['ab', '^ab'], ['ab', 'ab$']] as [$subject, $pattern]) {
                mb_ereg_search_init($subject);
                $results[$pattern] = mb_ereg_search($pattern, 'b');
            }
            foreach ($results as $pattern => $result) {
                $this->ensure($result === true, "BRE anchor pattern failed: $pattern");
            }
            return $results;
        }, false);

        $this->addCase('oniguruma', 'php_syntax_non_exposed_onig_additions', function (): array {
            $skip = $this->mbMatch('a(*SKIP)b', 'ab');
            $charTypeMinus = $this->mbMatch('[\w-%]', 'a');
            $wholeOptions = $this->mbMatch('(?Ii)$', '');
            $asciiWholeOption = $this->mbMatch('(?I)[s]', "\u{017F}");
            $callByNumber = $this->mbMatch('(abc)(?1)', 'abcabc');
            $callByRelativeNumber = $this->mbMatch('(abc)(?-1)', 'abcabc');
            $supportedRelativeCall = $this->mbMatch('(abc)\g<-1>', 'abcabc');
            $supportedForwardCall = $this->mbMatch('\g<+1>(abc)', 'abcabc');
            $contextRepeat = $this->mbMatch('^*', '*');
            $branchRepeat = $this->mbMatch('abc|?', '?');

            $this->ensure(!$skip['result'] && $skip['warnings'] !== [], '(*SKIP) unexpectedly compiled through PHP syntax');
            $this->ensure(!$charTypeMinus['result'] && $charTypeMinus['warnings'] !== [], '[\w-%] unexpectedly compiled through PHP syntax');
            $this->ensure(!$wholeOptions['result'] && $wholeOptions['warnings'] !== [], '(?Ii) unexpectedly compiled through PHP syntax');
            $this->ensure(!$asciiWholeOption['result'] && $asciiWholeOption['warnings'] !== [], '(?I) unexpectedly compiled through PHP syntax');
            $this->ensure(!$callByNumber['result'] && $callByNumber['warnings'] !== [], '(?1) unexpectedly compiled through PHP syntax');
            $this->ensure(!$callByRelativeNumber['result'] && $callByRelativeNumber['warnings'] !== [], '(?-1) unexpectedly compiled through PHP syntax');
            $this->ensure($supportedRelativeCall['result'] && $supportedForwardCall['result'], '\g numeric call behavior changed');
            $this->ensure(!$contextRepeat['result'] && $contextRepeat['warnings'] !== [], '^* unexpectedly compiled through PHP syntax');
            $this->ensure(!$branchRepeat['result'] && $branchRepeat['warnings'] !== [], 'abc|? unexpectedly compiled through PHP syntax');

            $this->recordFeature('php_exposes_skip_callout', $skip['result']);
            $this->recordFeature('php_exposes_char_type_minus', $charTypeMinus['result']);
            $this->recordFeature('php_exposes_whole_options', $wholeOptions['result'] || $asciiWholeOption['result']);
            $this->recordFeature('php_exposes_call_by_number_option_forms', $callByNumber['result'] || $callByRelativeNumber['result']);

            return compact('skip', 'charTypeMinus', 'wholeOptions', 'asciiWholeOption', 'callByNumber', 'callByRelativeNumber', 'supportedRelativeCall', 'supportedForwardCall', 'contextRepeat', 'branchRepeat');
        }, false);
    }

    private function writeReport(): void
    {
        $summary = [
            'total' => count($this->cases),
            'failures' => count(array_filter($this->cases, static fn (array $case): bool => $case['status'] === 'fail')),
            'skipped' => count(array_filter($this->cases, static fn (array $case): bool => $case['status'] === 'skip')),
        ];

        $report = [
            'profile' => $this->profile,
            'target' => [
                'php' => $this->expectedPhp,
                'arch' => $this->expectedArch,
                'ts' => $this->expectedTs,
            ],
            'environment' => [
                'php_version' => PHP_VERSION,
                'php_zts' => PHP_ZTS,
                'php_int_size' => PHP_INT_SIZE,
                'sapi' => PHP_SAPI,
                'oniguruma' => $this->onigVersion(),
                'extensions' => get_loaded_extensions(),
            ],
            'features' => $this->features,
            'summary' => $summary,
            'cases' => $this->cases,
        ];

        $directory = dirname($this->reportPath);
        if (!is_dir($directory)) {
            mkdir($directory, 0777, true);
        }
        file_put_contents($this->reportPath, json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);

        printf(
            "%s %s %s %s: %d checks, %d failures\n",
            $this->profile,
            $this->expectedPhp,
            $this->expectedArch,
            $this->expectedTs,
            $summary['total'],
            $summary['failures']
        );

        foreach ($this->cases as $case) {
            if ($case['status'] === 'fail') {
                printf("FAIL [%s] %s: %s\n", $case['area'], $case['name'], $case['details']['message'] ?? 'unknown');
            }
        }
    }
}

$options = getopt('', [
    'profile:',
    'php:',
    'arch:',
    'ts:',
    'require-onig::',
    'report:',
]);

$required = ['profile', 'php', 'arch', 'ts', 'report'];
foreach ($required as $key) {
    if (!isset($options[$key])) {
        fwrite(STDERR, "Missing required --$key option\n");
        exit(2);
    }
}

$suite = new FunctionalSuite(
    (string) $options['profile'],
    (string) $options['php'],
    (string) $options['arch'],
    (string) $options['ts'],
    isset($options['require-onig']) ? (string) $options['require-onig'] : null,
    (string) $options['report']
);

exit($suite->run());
