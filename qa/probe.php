<?php
// Record child return codes as well as output: PHPT otherwise hides crashes.
$settings = json_decode(file_get_contents($argv[1]), true, flags: JSON_THROW_ON_ERROR);
$variant = $argv[2];
$args = $settings['args'];
$code = 'echo "Test\n"; fprintf(STDERR, "Error");';
if ($variant === 'echo-only') $code = 'echo "Test\n";';
if ($variant === 'stderr-only') $code = 'fprintf(STDERR, "Error");';
$file = tempnam(sys_get_temp_dir(), 'PROC_OPEN_QA');
file_put_contents($file, '<?php ' . $code);
if ($variant === 'no-extra-args') $args = [];
if ($variant === 'no-child-opcache') array_push($args, '-d', 'opcache.enable_cli=0');
if ($variant === 'no-child-jit') array_push($args, '-d', 'opcache.jit_buffer_size=0', '-d', 'opcache.jit=disable');
if ($variant === 'no-child-optimizer') array_push($args, '-d', 'opcache.optimization_level=0');
if ($variant === 'no-child-protection') array_push($args, '-d', 'opcache.protect_memory=0');
$argvChild = array_merge([PHP_BINARY], $args, $variant === 'array-inline' ? ['-r', $code] : [$file]);
$command = str_starts_with($variant, 'array-') ? $argvChild : implode(' ', array_map('escapeshellarg', $argvChild));
$options = $variant === 'bypass-shell' ? ['bypass_shell' => true] : [];
$outputFile = $file . '.out';
echo 'CONFIG ', json_encode(['variant' => $variant, 'php' => PHP_VERSION, 'zts' => PHP_ZTS, 'opcache' => ini_get('opcache.enable_cli'), 'jit' => ini_get('opcache.jit'), 'jit_buffer' => ini_get('opcache.jit_buffer_size'), 'command' => $command]), "\n";
for ($repeat = 0; $repeat < 3; $repeat++) {
    foreach (['pipe', 'filename', 'file', 'inherited'] as $phase) {
        $stream = null;
        $spec = match ($phase) {
            'pipe' => [1 => ['pipe', 'w'], 2 => ['redirect', 1]],
            'filename' => [1 => ['file', $outputFile, 'w'], 2 => ['redirect', 1]],
            'file' => [1 => $stream = fopen($outputFile, 'w'), 2 => ['redirect', 1]],
            'inherited' => [2 => ['redirect', 1]],
        };
        echo 'START ', json_encode(['repeat' => $repeat, 'phase' => $phase]), "\n";
        $process = proc_open($command, $spec, $pipes, null, null, $options);
        $output = $phase === 'pipe' ? stream_get_contents($pipes[1]) : null;
        if ($phase === 'pipe') fclose($pipes[1]);
        $exit = proc_close($process);
        if ($stream) fclose($stream);
        if ($phase === 'file' || $phase === 'filename') {
            $output = file_get_contents($outputFile);
            unlink($outputFile);
        }
        echo "\nRESULT ", json_encode(['repeat' => $repeat, 'phase' => $phase, 'exit' => $exit, 'exit_hex' => sprintf('%08X', $exit), 'output' => $output]), "\n";
    }
}
unlink($file);
