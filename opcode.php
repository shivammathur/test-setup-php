<?php

function beta_probe(int $value): int
{
    return $value + 7;
}

echo 'EXECUTED-' . beta_probe(35) . PHP_EOL;
