<?php

declare(strict_types=1);

$options = getopt('', ['dir:', 'out:']);
$directory = $options['dir'] ?? 'reports';
$output = $options['out'] ?? 'comparison.md';

/**
 * @return list<string>
 */
function expectedTargets(): array
{
    $targets = [];
    foreach (['8.2', '8.3', '8.4', '8.5'] as $php) {
        foreach (['x64', 'x86'] as $arch) {
            foreach (['nts', 'ts'] as $threadSafety) {
                $targets[] = implode('-', [$php, $arch, $threadSafety]);
            }
        }
    }
    sort($targets);
    return $targets;
}

/**
 * @return array<string, array{artifact: bool, release: bool}>
 */
function expectedFeatureDiffs(?string $artifactOnig, ?string $releaseOnig): array
{
    $diffs = [];
    if ($artifactOnig === null || $releaseOnig === null) {
        return $diffs;
    }

    if (version_compare($artifactOnig, '6.9.9', '>=') && version_compare($releaseOnig, '6.9.9', '<')) {
        foreach ([
            'bounded_quantifier_short_newline_input',
            'posix_bracket_parser_edges',
            'posix_punct_symbols',
            'posix_punct_generated_corpus',
            'unicode_15_kawi',
            'unicode_15_kawi_corpus',
            'unicode_15_nag_mundari',
            'unicode_15_nag_mundari_corpus',
        ] as $feature) {
            $diffs[$feature] = ['artifact' => true, 'release' => false];
        }
    }

    if (version_compare($artifactOnig, '6.9.10', '>=') && version_compare($releaseOnig, '6.9.10', '<')) {
        foreach ([
            'lookbehind_anchor_empty_match',
            'retry_limit_zero_unlimited',
            'unicode_16_garay',
            'unicode_16_garay_corpus',
        ] as $feature) {
            $diffs[$feature] = ['artifact' => true, 'release' => false];
        }
    }

    ksort($diffs);
    return $diffs;
}

$profiles = ['artifact', 'release'];
$targets = [];

$reportDirectory = new RecursiveDirectoryIterator($directory, FilesystemIterator::SKIP_DOTS);
$reportFiles = new RecursiveIteratorIterator($reportDirectory);
foreach ($reportFiles as $fileInfo) {
    if (!$fileInfo->isFile() || strtolower($fileInfo->getExtension()) !== 'json') {
        continue;
    }
    $file = $fileInfo->getPathname();
    $data = json_decode((string) file_get_contents($file), true, 512, JSON_THROW_ON_ERROR);
    $key = implode('-', [$data['target']['php'], $data['target']['arch'], $data['target']['ts']]);
    $targets[$key][$data['profile']] = $data;
}

ksort($targets);

$failures = [];
$expectedTargets = expectedTargets();
foreach ($expectedTargets as $target) {
    if (!isset($targets[$target])) {
        $failures[] = "Missing all reports for expected target $target";
    }
}
foreach (array_keys($targets) as $target) {
    if (!in_array($target, $expectedTargets, true)) {
        $failures[] = "Unexpected report target $target";
    }
}

$lines = [];
$lines[] = '# Oniguruma PHP Artifact Comparison';
$lines[] = '';
$lines[] = '| Target | Artifact PHP / Onig | Artifact result | Latest release PHP / Onig | Release result | Feature differences |';
$lines[] = '| --- | --- | --- | --- | --- | --- |';

foreach ($targets as $key => $reports) {
    foreach ($profiles as $profile) {
        if (!isset($reports[$profile])) {
            $failures[] = "Missing $profile report for $key";
        }
    }
    if (!isset($reports['artifact'], $reports['release'])) {
        continue;
    }

    $artifact = $reports['artifact'];
    $release = $reports['release'];

    foreach (['artifact' => $artifact, 'release' => $release] as $profile => $report) {
        if (($report['summary']['failures'] ?? 0) > 0) {
            $failures[] = "$profile report for $key has {$report['summary']['failures']} failing checks";
        }
    }

    $featureDiffs = [];
    $actualFeatureDiffs = [];
    $featureNames = array_unique(array_merge(
        array_keys($artifact['features'] ?? []),
        array_keys($release['features'] ?? [])
    ));
    sort($featureNames);
    foreach ($featureNames as $feature) {
        $artifactValue = $artifact['features'][$feature] ?? null;
        $releaseValue = $release['features'][$feature] ?? null;
        if ($artifactValue !== $releaseValue) {
            $actualFeatureDiffs[$feature] = ['artifact' => $artifactValue, 'release' => $releaseValue];
            $featureDiffs[] = sprintf(
                '%s: artifact=%s release=%s',
                $feature,
                json_encode($artifactValue),
                json_encode($releaseValue)
            );
        }
    }

    $expectedFeatureDiffs = expectedFeatureDiffs(
        isset($artifact['environment']['oniguruma']) ? (string) $artifact['environment']['oniguruma'] : null,
        isset($release['environment']['oniguruma']) ? (string) $release['environment']['oniguruma'] : null
    );
    foreach ($actualFeatureDiffs as $feature => $values) {
        if (($expectedFeatureDiffs[$feature] ?? null) !== $values) {
            $failures[] = sprintf(
                'Unexpected feature diff for %s: %s artifact=%s release=%s',
                $key,
                $feature,
                json_encode($values['artifact']),
                json_encode($values['release'])
            );
        }
    }
    foreach ($expectedFeatureDiffs as $feature => $values) {
        if (($actualFeatureDiffs[$feature] ?? null) !== $values) {
            $failures[] = sprintf(
                'Expected feature diff was not observed for %s: %s artifact=%s release=%s',
                $key,
                $feature,
                json_encode($values['artifact']),
                json_encode($values['release'])
            );
        }
    }

    $artifactResult = sprintf(
        '%d checks, %d failures',
        $artifact['summary']['total'],
        $artifact['summary']['failures']
    );
    $releaseResult = sprintf(
        '%d checks, %d failures',
        $release['summary']['total'],
        $release['summary']['failures']
    );

    $lines[] = sprintf(
        '| `%s` | `%s` / `%s` | %s | `%s` / `%s` | %s | %s |',
        $key,
        $artifact['environment']['php_version'],
        $artifact['environment']['oniguruma'] ?? 'n/a',
        $artifactResult,
        $release['environment']['php_version'],
        $release['environment']['oniguruma'] ?? 'n/a',
        $releaseResult,
        $featureDiffs ? implode('<br>', array_map('htmlspecialchars', $featureDiffs)) : 'none'
    );
}

$lines[] = '';
if ($failures) {
    $lines[] = '## Failures';
    foreach ($failures as $failure) {
        $lines[] = "- $failure";
    }
} else {
    $lines[] = 'No functional-suite failures were reported.';
}

file_put_contents($output, implode(PHP_EOL, $lines) . PHP_EOL);
echo implode(PHP_EOL, $lines), PHP_EOL;

exit($failures ? 1 : 0);
