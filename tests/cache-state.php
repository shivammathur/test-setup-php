<?php
header('Content-Type: application/json');
$proof = __DIR__ . '/cache-proof.php';
$mode = $_GET['mode'] ?? 'check';
$result = ['pid' => getmypid(), 'sapi' => PHP_SAPI];
if ($mode === 'prime') {
    $result['compiled'] = opcache_compile_file($proof);
} elseif ($mode === 'reset') {
    $result['reset_accepted'] = opcache_reset();
}
$status = opcache_get_status(false);
if ($status === false) {
    http_response_code(500);
    echo json_encode(['error' => 'OPcache is disabled']);
    exit;
}
$result += [
    'cached' => opcache_is_script_cached($proof),
    'restart_pending' => $status['restart_pending'],
    'restart_in_progress' => $status['restart_in_progress'],
    'start_time' => $status['opcache_statistics']['start_time'],
    'manual_restarts' => $status['opcache_statistics']['manual_restarts'],
    'cached_scripts' => $status['opcache_statistics']['num_cached_scripts'],
    'hits' => $status['opcache_statistics']['hits'],
];
echo json_encode($result, JSON_THROW_ON_ERROR);
