<?php
error_reporting(E_ALL);
set_error_handler(static function ($severity, $message, $file, $line) {
    throw new ErrorException($message, 0, $severity, $file, $line);
});
header('Content-Type: application/json');
try {
    if (!extension_loaded('curl') || !extension_loaded('intl')) {
        throw new RuntimeException('curl or intl did not load');
    }
    // GH-16900: ICU mutex crash with an incompatible C++ runtime under Apache.
    $formatter = datefmt_create('fr_CA', IntlDateFormatter::FULL, IntlDateFormatter::FULL, 'America/Toronto', IntlDateFormatter::GREGORIAN);
    $formatted = $formatter->format(0);
    $normalized = Normalizer::normalize("e\u{0301}", Normalizer::FORM_C);
    $number = (new NumberFormatter('en_US', NumberFormatter::DECIMAL))->format(1234.5);
    if (!$formatted || $normalized !== "\u{00e9}" || $number !== '1,234.5') {
        throw new RuntimeException('Intl operation failed');
    }
    // Exercise the upstream record_errors_001.phpt reproducer in Apache's VM.
    $recorded = [];
    set_error_handler(static function ($severity, $message) use (&$recorded) {
        $recorded[] = $message;
        new class extends DateTime {};
        return true;
    });
    try { include __DIR__ . '/record-errors.php'; }
    finally { restore_error_handler(); }
    if (count($recorded) !== 1 || !str_contains($recorded[0], 'getTimezone()')) {
        throw new RuntimeException('Recorded-error VM reentry failed');
    }
    $curl = curl_version();
    if (!($curl['features'] & CURL_VERSION_NTLM)) {
        throw new RuntimeException('cURL NTLM feature missing');
    }
    // GH-22023: create session state on concurrently initialized Apache threads.
    session_start();
    $_SESSION['request'] = $_GET['request'] ?? '';
    session_write_close();
    usleep(50000);
    echo json_encode([
        'passed' => true, 'php' => PHP_VERSION, 'pid' => getmypid(),
        'trans_sid' => ini_get('session.use_trans_sid'), 'icu' => INTL_ICU_VERSION,
        'recordedErrors' => count($recorded), 'formatted' => $formatted, 'number' => $number, 'curl' => $curl['version'], 'ntlm' => true,
    ], JSON_THROW_ON_ERROR);
} catch (Throwable $e) {
    http_response_code(500);
    echo json_encode(['error' => get_class($e) . ': ' . $e->getMessage()], JSON_THROW_ON_ERROR);
}
