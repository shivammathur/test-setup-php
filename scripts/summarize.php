<?php

declare(strict_types=1);

if ($argc !== 4) {
    fwrite(STDERR, "Usage: summarize.php <test-id> <test-label> <results-directory>\n");
    exit(2);
}

[$script, $testId, $testLabel, $resultsDirectory] = $argv;
$samples = [];
$suites = ['phpstan', 'pgo-script', 'pgo-script-opcache', 'zend-bench', 'untrained-extensions'];
$suitePattern = implode('|', array_map(static fn(string $suite): string => preg_quote($suite, '/'), $suites));

foreach (glob($resultsDirectory . '/benchmarks/*.json') ?: [] as $path) {
    $name = basename($path, '.json');
    if (!preg_match('/^(' . $suitePattern . ')-(baseline|optimized)-\d+$/', $name, $matches)) {
        continue;
    }

    $document = json_decode((string) file_get_contents($path), true, flags: JSON_THROW_ON_ERROR);
    foreach ($document['results'][0]['times'] as $seconds) {
        $samples[$matches[1]][$matches[2]][] = (float) $seconds;
    }
}

$median = static function (array $values): float {
    sort($values, SORT_NUMERIC);
    $count = count($values);
    $middle = intdiv($count, 2);
    return $count % 2 === 0
        ? ($values[$middle - 1] + $values[$middle]) / 2
        : $values[$middle];
};

$mean = static fn(array $values): float => array_sum($values) / count($values);
$improvement = static fn(float $baseline, float $optimized): float => (1 - ($optimized / $baseline)) * 100;
$delta = static fn(float $baseline, float $optimized): float => (($optimized / $baseline) - 1) * 100;

$readTsv = static function (string $path): array {
    $rows = [];
    $handle = fopen($path, 'rb');
    $headers = fgetcsv($handle, separator: "\t");
    while (($values = fgetcsv($handle, separator: "\t")) !== false) {
        $row = array_combine($headers, $values);
        $rows[$row['variant']] = $row;
    }
    fclose($handle);
    return $rows;
};

$sizeRows = $readTsv($resultsDirectory . '/sizes.tsv');
$buildRows = $readTsv($resultsDirectory . '/build-times.tsv');
$symbolRows = $readTsv($resultsDirectory . '/symbols.tsv');

$markdown = [];
$markdown[] = "## Apple Clang flags: $testLabel";
$markdown[] = '';
$markdown[] = '`-mno-outline -Xclang -fno-split-cold-code`';
$markdown[] = '';
$markdown[] = '| Benchmark | Samples/variant | Baseline mean | Optimized mean | Mean improvement | Median improvement |';
$markdown[] = '|---|---:|---:|---:|---:|---:|';

$tsv = ["test_id\ttype\tname\tbaseline\toptimized\tdelta_percent"];
foreach ($suites as $suite) {
    $baseline = $samples[$suite]['baseline'] ?? [];
    $optimized = $samples[$suite]['optimized'] ?? [];
    if ($baseline === [] || count($baseline) !== count($optimized)) {
        throw new RuntimeException("Missing or unbalanced samples for $suite");
    }

    $baselineMean = $mean($baseline);
    $optimizedMean = $mean($optimized);
    $meanImprovement = $improvement($baselineMean, $optimizedMean);
    $medianImprovement = $improvement($median($baseline), $median($optimized));
    $markdown[] = sprintf(
        '| %s | %d | %.6f s | %.6f s | %+.3f%% | %+.3f%% |',
        $suite,
        count($baseline),
        $baselineMean,
        $optimizedMean,
        $meanImprovement,
        $medianImprovement,
    );
    $tsv[] = implode("\t", [$testId, 'benchmark', $suite, $baselineMean, $optimizedMean, $meanImprovement]);
}

$markdown[] = '';
$markdown[] = '| Build | Baseline | Optimized | Difference |';
$markdown[] = '|---|---:|---:|---:|';
$baselineBuild = (int) $buildRows['baseline']['build_seconds'];
$optimizedBuild = (int) $buildRows['optimized']['build_seconds'];
$markdown[] = sprintf(
    '| Source install | %dm %02ds | %dm %02ds | %+d s |',
    intdiv($baselineBuild, 60),
    $baselineBuild % 60,
    intdiv($optimizedBuild, 60),
    $optimizedBuild % 60,
    $optimizedBuild - $baselineBuild,
);
$tsv[] = implode("\t", [$testId, 'build', 'source-install-seconds', $baselineBuild, $optimizedBuild, $delta((float) $baselineBuild, (float) $optimizedBuild)]);

$markdown[] = '';
$markdown[] = '| Artifact | Baseline bytes | Optimized bytes | Delta |';
$markdown[] = '|---|---:|---:|---:|';
foreach (['cli_bytes' => 'CLI', 'payload_bytes' => 'Installed payload', 'bottle_bytes' => 'Bottle'] as $key => $label) {
    $baseline = (int) $sizeRows['baseline'][$key];
    $optimized = (int) $sizeRows['optimized'][$key];
    $percent = $delta((float) $baseline, (float) $optimized);
    $markdown[] = sprintf(
        '| %s | %s | %s | %+.3f%% (%+d B) |',
        $label,
        number_format($baseline),
        number_format($optimized),
        $percent,
        $optimized - $baseline,
    );
    $tsv[] = implode("\t", [$testId, 'size', $key, $baseline, $optimized, $percent]);
}

$markdown[] = '';
$markdown[] = '| CLI symbols | Baseline | Optimized | Difference |';
$markdown[] = '|---|---:|---:|---:|';
foreach (['outlined_symbols' => 'OUTLINED_FUNCTION', 'cold_symbols' => '.cold'] as $key => $label) {
    $baseline = (int) $symbolRows['baseline'][$key];
    $optimized = (int) $symbolRows['optimized'][$key];
    $markdown[] = sprintf('| %s | %d | %d | %+d |', $label, $baseline, $optimized, $optimized - $baseline);
    $tsv[] = implode("\t", [$testId, 'symbols', $key, $baseline, $optimized, $optimized - $baseline]);
}

$markdown[] = '';
$markdown[] = 'Positive benchmark percentages mean the optimized build was faster.';
$markdown[] = '';

file_put_contents($resultsDirectory . '/summary.md', implode("\n", $markdown));
file_put_contents($resultsDirectory . '/summary.tsv', implode("\n", $tsv) . "\n");
