<?php

declare(strict_types=1);

$iterations = isset($argv[1]) ? max(1, (int) $argv[1]) : 100000;

function hot_path(int $seed): int
{
    $total = 0;
    $buffer = range(1, 16);

    for ($outer = 0; $outer < 16; $outer++) {
        foreach ($buffer as $index => $value) {
            $tmp = ($value + $seed + $outer + $index) ^ (($seed << ($index % 5)) & 0xffff);

            if (($tmp & 1) === 0) {
                $total += ($tmp >> 1) + ($index * 3);
            } else {
                $total -= ($tmp << 1) - $outer;
            }

            $seed = (($seed * 251 + 13849) ^ ($total & 0xffff)) & 0xffff;
        }

        $buffer[$outer % 16] = ($total ^ $seed) & 0xffff;
        sort($buffer);
    }

    return $total ^ $seed;
}

$checksum = 0;

for ($i = 0; $i < $iterations; $i++) {
    $checksum ^= hot_path($i + 1);
}

echo $checksum, PHP_EOL;
