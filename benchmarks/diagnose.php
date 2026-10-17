<?php
declare(strict_types=1);

function without_sort(int $seed): int {
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
    }
    return $total ^ $seed;
}

function sorting(int $n): int {
    $a = range(1, 16);
    $total = 0;
    for ($i = 0; $i < $n; $i++) {
        $a[$i % 16] = ($i * 251 + 13849) & 0xffff;
        sort($a);
        $total ^= $a[0];
    }
    return $total;
}

function arithmetic(int $n): int {
    $seed = 1;
    $total = 0;
    for ($i = 0; $i < $n; $i++) {
        $tmp = ($seed + $i) ^ (($seed << ($i % 5)) & 0xffff);
        if (($tmp & 1) === 0) {
            $total += ($tmp >> 1) + ($i % 16);
        } else {
            $total -= ($tmp << 1) - ($i % 16);
        }
        $seed = (($seed * 251 + 13849) ^ ($total & 0xffff)) & 0xffff;
    }
    return $total ^ $seed;
}

function foreach_keyed(int $n): int {
    $a = range(1, 256);
    $sum = 0;
    for ($i = 0; $i < $n; $i++) {
        foreach ($a as $key => $value) { $sum += $key + $value; }
    }
    return $sum;
}

function foreach_value(int $n): int {
    $a = range(1, 256);
    $sum = 0;
    for ($i = 0; $i < $n; $i++) {
        foreach ($a as $value) { $sum += $value; }
    }
    return $sum;
}

$mode = $argv[1];
$checksum = 0;
$start = hrtime(true);
switch ($mode) {
    case 'vm':
    case 'mixed':
        $script = $mode;
        $argv = [$script];
        ob_start();
        require __DIR__ . '/' . $script . '.php';
        $output = ob_get_clean();
        $checksum = trim($output);
        break;
    case 'no-sort':
        for ($i = 0; $i < 100000; $i++) { $checksum ^= without_sort($i + 1); }
        break;
    case 'sort':
        $checksum = sorting(1600000);
        break;
    case 'arithmetic':
        $checksum = arithmetic(10000000);
        break;
    case 'foreach-key':
    case 'foreach-key-raw':
        $checksum = foreach_keyed(200000);
        break;
    case 'foreach-value':
    case 'foreach-value-raw':
        $checksum = foreach_value(200000);
        break;
    case 'empty':
        break;
    default:
        throw new RuntimeException('Unknown mode');
}
$elapsed = (hrtime(true) - $start) / 1e6;
$status = opcache_get_status(false);
echo json_encode(['mode' => $mode, 'checksum' => (string) $checksum, 'inner_ms' => $elapsed,
    'jit' => $status ? ($status['jit'] ?? null) : null], JSON_THROW_ON_ERROR), PHP_EOL;
