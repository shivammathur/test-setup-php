<?php

declare(strict_types=1);

const ITERATIONS = 2_500_000;

for ($i = 0; $i < 50_000; $i++) {
    eval('return 1 + 2;');
}

$start = hrtime(true);
for ($i = 0; $i < ITERATIONS; $i++) {
    eval('return 1 + 2;');
}
$elapsed = (hrtime(true) - $start) / 1_000_000_000;

printf("Total %.6f\n", $elapsed);
