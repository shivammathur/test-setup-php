<?php

declare(strict_types=1);

$scale = isset($argv[1]) ? max(1, (int) $argv[1]) : 20;
$checksum = 0;

for ($pass = 0; $pass < 4 * $scale; $pass++) {
    $records = [];

    for ($i = 0; $i < 3000; $i++) {
        $records[] = [
            'id' => $i,
            'slug' => sprintf('record-%04d', $i),
            'name' => str_repeat(chr(65 + ($i % 26)), 8),
            'left' => $i % 97,
            'right' => ($i * 7) % 101,
        ];
    }

    $json = json_encode($records, JSON_THROW_ON_ERROR);
    $records = json_decode($json, true, 512, JSON_THROW_ON_ERROR);

    usort(
        $records,
        static fn(array $a, array $b): int => [$a['right'], $a['id']] <=> [$b['right'], $b['id']]
    );

    $bucket = [];
    foreach ($records as $record) {
        $key = preg_replace('/[^a-z0-9]+/i', '-', strtolower($record['slug']));
        $bucket[$key] = hash('sha256', serialize($record));
    }

    arsort($bucket);
    foreach (array_slice($bucket, 0, 800, true) as $key => $digest) {
        $checksum ^= strlen($key) + hexdec(substr($digest, 0, 6));
    }
}

interface ValueProvider
{
    public function value(): int;
}

final class NumberValue implements ValueProvider
{
    public function __construct(private int $number)
    {
    }

    public function value(): int
    {
        return (($this->number * 33) ^ ($this->number >> 2)) & 0xffff;
    }
}

for ($round = 0; $round < 160000 * $scale; $round++) {
    $value = new NumberValue($round);
    $checksum ^= $value->value();
}

echo $checksum, PHP_EOL;
