<?php

$phase = $argv[1] ?? 'activation';
$callMethod = ($argv[2] ?? '0') === '1';
$started = hrtime(true);
$created = null;
$result = [
    'phase' => $phase,
    'pid' => getmypid(),
    'success' => false,
    'code' => null,
    'hex' => null,
    'message' => null,
    'create_ms' => null,
    'total_ms' => null,
    'x' => null,
    'y' => null,
];

try {
    $createStarted = hrtime(true);
    $created = new com('InternetExplorer.Application');
    $result['create_ms'] = (hrtime(true) - $createStarted) / 1e6;

    if ($callMethod) {
        $x = 0;
        $y = 0;
        try {
            $created->clientToWindow($x, $y);
        } catch (com_exception $methodError) {
            // The PHPT intentionally tolerates clientToWindow failures. Creation is
            // the behavior this probe measures.
        }
        $result['x'] = $x;
        $result['y'] = $y;
    }

    $created->quit();
    $result['success'] = true;
} catch (Throwable $error) {
    $code = (int) $error->getCode();
    $result['code'] = $code;
    $result['hex'] = sprintf('0x%08X', $code);
    $result['message'] = $error->getMessage();
} finally {
    if ($created !== null) {
        unset($created);
    }
    gc_collect_cycles();
}

$result['total_ms'] = (hrtime(true) - $started) / 1e6;
echo json_encode($result, JSON_UNESCAPED_SLASHES), PHP_EOL;
exit($result['success'] ? 0 : 1);

