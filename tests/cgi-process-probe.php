<?php
declare(strict_types=1);
$root = dirname(PHP_BINARY);
$cgi = $root . DIRECTORY_SEPARATOR . 'php-cgi.exe';
$fixture = $root . DIRECTORY_SEPARATOR . 'process-control.php';
file_put_contents($fixture, '<?php echo "PROCESS_CONTROL";');
$report = ['php' => PHP_VERSION, 'bits' => PHP_INT_SIZE * 8, 'zts' => PHP_ZTS, 'cases' => [], 'failures' => []];
$commands = [
    'cgi' => [$cgi, '-n', '-s', 'missing-process-probe-file'],
    'cli' => [PHP_BINARY, '-n', $fixture],
];
foreach ($commands as $kind => $arguments) {
    $command = implode(' ', array_map('escapeshellarg', $arguments));
    foreach (['proc-direct', 'proc-shell', 'exec', 'shell_exec'] as $method) {
        $key = $kind . '/' . $method;
        $report['cases'][$key] = ['attempts' => 0, 'exitCodes' => [], 'failures' => 0];
        for ($i = 0; $i < 100; $i++) {
            $stderr = '';
            $exit = null;
            if (str_starts_with($method, 'proc-')) {
                $process = proc_open($method === 'proc-direct' ? $arguments : $command, [0 => ['file', 'NUL', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
                if (!is_resource($process)) {
                    $stdout = ''; $stderr = 'proc_open failed';
                } else {
                    $stdout = stream_get_contents($pipes[1]);
                    $stderr = stream_get_contents($pipes[2]);
                    fclose($pipes[1]); fclose($pipes[2]);
                    $exit = proc_close($process);
                }
            } elseif ($method === 'exec') {
                $output = [];
                exec($command . ' 2>&1', $output, $exit);
                $stdout = implode("\n", $output);
            } else {
                $stdout = shell_exec($command . ' 2>&1') ?? '';
            }
            $entry = &$report['cases'][$key];
            $entry['attempts']++;
            $exitKey = $exit === null ? 'unavailable' : (string) $exit;
            $entry['exitCodes'][$exitKey] = ($entry['exitCodes'][$exitKey] ?? 0) + 1;
            $expected = $kind === 'cgi' ? 'No input file specified.' : 'PROCESS_CONTROL';
            if (!str_contains($stdout, $expected)) {
                $entry['failures']++;
                $report['failures'][] = ['case' => $key, 'attempt' => $i + 1, 'exit' => $exit, 'stdout' => $stdout, 'stderr' => $stderr];
            }
            unset($entry);
        }
    }
}
file_put_contents($argv[1], json_encode($report, JSON_PRETTY_PRINT | JSON_INVALID_UTF8_SUBSTITUTE) . "\n");
echo json_encode(['cases' => $report['cases'], 'failureCount' => count($report['failures'])], JSON_PRETTY_PRINT), "\n";
exit($report['failures'] ? 1 : 0);
