<?php
header('Content-Type: application/json');
echo json_encode([
    'php' => PHP_VERSION,
    'pid' => getmypid(),
    'digest' => hash('sha256', str_repeat('OPcache throughput.', 1024)),
    'opcache' => opcache_get_status(false) !== false,
], JSON_THROW_ON_ERROR);
