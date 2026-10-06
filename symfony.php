<?php

use Symfony\Component\Process\Process;

spl_autoload_register(static function (string $class): void {
    $prefix = 'Symfony\\Component\\Process\\';
    if (str_starts_with($class, $prefix)) {
        require __DIR__ . '/symfony-process/' . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
    }
});

$basedir = __DIR__ . ';' . dirname(PHP_BINARY);
if (ini_set('open_basedir', $basedir) === false) {
    throw new RuntimeException('Could not set open_basedir');
}
$results = [];
foreach ([false, true] as $disabled) {
    $warnings = [];
    set_error_handler(static function (int $type, string $message) use (&$warnings): bool {
        $warnings[] = $message;
        return true;
    });
    try {
        $process = new Process([PHP_BINARY, '-n', '-r', 'fwrite(STDOUT, "out"); fwrite(STDERR, "err");']);
        if ($disabled) {
            $process->disableOutput();
        }
        $exit = $process->run();
        $result = ['success' => $exit === 0 && ($disabled || ($process->getOutput() === 'out' && $process->getErrorOutput() === 'err'))];
    } catch (Throwable $error) {
        $result = ['success' => false, 'error' => $error->getMessage()];
    } finally {
        unset($process);
        restore_error_handler();
    }
    $results[$disabled ? 'disabled' : 'captured'] = $result + ['warnings' => $warnings];
}
echo json_encode([
    'php' => PHP_VERSION,
    'zts' => (bool) PHP_ZTS,
    'bits' => PHP_INT_SIZE * 8,
    'os' => php_uname(),
    'open_basedir' => ini_get('open_basedir'),
    'results' => $results,
], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
