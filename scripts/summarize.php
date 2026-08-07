<?php

declare(strict_types=1);

if ($argc !== 3) {
    fwrite(STDERR, "Usage: summarize.php <architecture> <results-directory>\n");
    exit(2);
}

[$script, $architecture, $resultsDirectory] = $argv;
$samples = [];

foreach (glob($resultsDirectory . '/benchmarks/*.json') ?: [] as $path) {
    $name = basename($path, '.json');
    if (!preg_match('/^(phpstan|pgo-script|zend-bench|untrained-extensions)-(baseline|partial)-\d+$/', $name, $matches)) {
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
$percent = static fn(float $baseline, float $partial): float => (($partial / $baseline) - 1) * 100;

$sizeRows = [];
$handle = fopen($resultsDirectory . '/sizes.tsv', 'rb');
fgetcsv($handle, separator: "\t");
while (($row = fgetcsv($handle, separator: "\t")) !== false) {
    $sizeRows[$row[0]] = [
        'cli' => (int) $row[1],
        'payload' => (int) $row[2],
        'bottle' => (int) $row[3],
    ];
}
fclose($handle);

$markdown = [];
$markdown[] = "## PHP PGO comparison ($architecture)";
$markdown[] = '';
$markdown[] = '| Benchmark | Samples/variant | Baseline mean | Partial mean | Mean delta | Median delta |';
$markdown[] = '|---|---:|---:|---:|---:|---:|';

$tsv = ["type\tname\tbaseline\tpartial\tdelta_percent"];
foreach (['phpstan', 'pgo-script', 'zend-bench', 'untrained-extensions'] as $suite) {
    $baseline = $samples[$suite]['baseline'] ?? [];
    $partial = $samples[$suite]['partial'] ?? [];
    if ($baseline === [] || count($baseline) !== count($partial)) {
        throw new RuntimeException("Missing or unbalanced samples for $suite");
    }

    $baselineMean = $mean($baseline);
    $partialMean = $mean($partial);
    $meanDelta = $percent($baselineMean, $partialMean);
    $medianDelta = $percent($median($baseline), $median($partial));
    $markdown[] = sprintf(
        '| %s | %d | %.6f s | %.6f s | %+.3f%% | %+.3f%% |',
        $suite,
        count($baseline),
        $baselineMean,
        $partialMean,
        $meanDelta,
        $medianDelta,
    );
    $tsv[] = implode("\t", ['benchmark', $suite, $baselineMean, $partialMean, $meanDelta]);
}

$markdown[] = '';
$markdown[] = '| Artifact | Baseline bytes | Partial bytes | Delta |';
$markdown[] = '|---|---:|---:|---:|';
foreach (['cli', 'payload', 'bottle'] as $artifact) {
    $baseline = $sizeRows['baseline'][$artifact];
    $partial = $sizeRows['partial'][$artifact];
    $delta = $percent((float) $baseline, (float) $partial);
    $markdown[] = sprintf(
        '| %s | %s | %s | %+.3f%% (%+d B) |',
        $artifact,
        number_format($baseline),
        number_format($partial),
        $delta,
        $partial - $baseline,
    );
    $tsv[] = implode("\t", ['size', $artifact, $baseline, $partial, $delta]);
}

$markdown[] = '';
$markdown[] = 'Negative benchmark deltas mean the partial-training build was faster.';
$markdown[] = '';

file_put_contents($resultsDirectory . '/summary.md', implode("\n", $markdown));
file_put_contents($resultsDirectory . '/summary.tsv', implode("\n", $tsv) . "\n");
