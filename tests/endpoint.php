<?php
error_reporting(E_ALL);
set_error_handler(static function ($severity, $message, $file, $line) { throw new ErrorException($message, 0, $severity, $file, $line); });
$payload = file_get_contents(__DIR__ . '/payload.txt');
$mode = $_GET['mode'] ?? 'info';
if ($mode === 'payload') { header('Content-Type: text/plain'); echo $payload; exit; }
if ($mode === 'php-gzip') { header('Content-Type: text/plain'); header('Content-Encoding: gzip'); echo gzencode($payload); exit; }
header('Content-Type: application/json');
try {
    if ($mode === 'post') {
        $decoded = gzdecode(file_get_contents('php://input'));
        if ($decoded !== $payload) { throw new RuntimeException('Compressed request body mismatch'); }
        echo json_encode(['sha256' => hash('sha256', $decoded), 'size' => strlen($decoded)], JSON_THROW_ON_ERROR);
        exit;
    }
    if ($mode === 'session') {
        session_start();
        $_SESSION['count'] = ($_SESSION['count'] ?? 0) + 1;
        echo json_encode(['id' => session_id(), 'count' => $_SESSION['count']], JSON_THROW_ON_ERROR);
        exit;
    }
    foreach (['compress' => ['gzcompress', 'gzuncompress'], 'deflate' => ['gzdeflate', 'gzinflate'], 'gzip' => ['gzencode', 'gzdecode']] as $name => $functions) {
        if ($functions[1]($functions[0]($payload)) !== $payload) { throw new RuntimeException("PHP $name round trip failed"); }
    }
    $curl = curl_version();
    $http = [];
    foreach (['identity', 'gzip', 'br'] as $encoding) {
        $handle = curl_init('http://' . $_SERVER['HTTP_HOST'] . '/payload.txt');
        $responseEncoding = '';
        curl_setopt_array($handle, [CURLOPT_RETURNTRANSFER => true, CURLOPT_ENCODING => $encoding, CURLOPT_TIMEOUT => 15, CURLOPT_PROXY => '',
            CURLOPT_HEADERFUNCTION => static function ($handle, $header) use (&$responseEncoding) {
                if (stripos($header, 'Content-Encoding:') === 0) { $responseEncoding = trim(substr($header, strlen('Content-Encoding:'))); }
                return strlen($header);
            }
        ]);
        $body = curl_exec($handle);
        $status = curl_getinfo($handle, CURLINFO_RESPONSE_CODE);
        if ($body !== $payload || $status !== 200) { throw new RuntimeException("cURL $encoding failed: " . curl_error($handle)); }
        if ($responseEncoding !== ($encoding === 'identity' ? '' : $encoding)) { throw new RuntimeException("cURL $encoding did not receive the requested encoding: $responseEncoding"); }
        $http[$encoding] = ['status' => $status, 'encoding' => $responseEncoding, 'sha256' => hash('sha256', $body)];
        unset($handle);
    }
    echo json_encode([
        'php' => PHP_VERSION, 'sapi' => PHP_SAPI, 'zts' => PHP_ZTS, 'bits' => PHP_INT_SIZE * 8,
        'zlib' => ZLIB_VERSION, 'curl_zlib' => $curl['libz_version'], 'curl' => $curl['version'],
        'apache' => function_exists('apache_get_version') ? apache_get_version() : $_SERVER['SERVER_SOFTWARE'],
        'opcache_loaded' => extension_loaded('Zend OPcache'),
        'opcache_enabled' => function_exists('opcache_get_status') && opcache_get_status(false) !== false,
        'sha256' => hash('sha256', $payload), 'curl_http' => $http
    ], JSON_THROW_ON_ERROR);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => get_class($e) . ': ' . $e->getMessage()], JSON_THROW_ON_ERROR);
}
