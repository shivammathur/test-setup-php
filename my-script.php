<?php

declare(strict_types=1);

function buildReport(array $numbers): array
{
    $sum = 0;

    foreach ($numbers as $number) {
        $sum += $number;
    }

    return [
        'count' => count($numbers),
        'sum' => $sum,
        'average' => $sum / max(1, count($numbers)),
    ];
}

$report = buildReport(range(1, 1000));

printf(
    "Blackfire sample: count=%d sum=%d average=%.2f\n",
    $report['count'],
    $report['sum'],
    $report['average']
);
