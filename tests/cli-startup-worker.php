<?php
$iterations = (int) $argv[1];
$report = $argv[2];
$root = sys_get_temp_dir() . '/winlibs-cli-probe-' . getmypid();
mkdir($root);
file_put_contents($root . '/index.php', '<?php echo "okey";');
$rows = [];
for ($i = 0; $i < $iterations; $i++) {
    $output = $root . '/output-' . $i . '.log';
    $fd = fopen($output, 'ab');
    $cmd = [PHP_BINARY, '-d', 'error_include_args=0', '-t', $root, '-n', '-S', 'localhost:0', 'index.php'];
    $started = microtime(true);
    $process = proc_open($cmd, [0 => STDIN, 1 => $fd, 2 => $fd], $pipes, $root, null, ['suppress_errors' => true]);
    $status = null; $bound = null; $text = ''; $body = false;
    if (is_resource($process)) {
        for ($j = 0; $j < 60; $j++) {
            usleep(50000);
            $status = proc_get_status($process);
            $text = file_get_contents($output);
            if (!$status['running']) break;
            if (preg_match('@PHP \S* Development Server \(https?://(.*?:\d+)\) started@', $text, $matches)) {
                $bound = $matches[1]; break;
            }
        }
        if ($bound !== null) {
            $body = @file_get_contents('http://' . $bound, false, stream_context_create(['http' => ['timeout' => 5]]));
        }
        $passed = $bound !== null && $body === 'okey';
        $rows[] = ['iteration' => $i, 'passed' => $passed, 'status' => $status, 'output' => $text,
            'body' => $body, 'seconds' => microtime(true) - $started];
        proc_terminate($process);
        proc_close($process);
    } else {
        $rows[] = ['iteration' => $i, 'passed' => false, 'error' => 'proc_open returned false'];
    }
    fclose($fd);
    if ($rows[array_key_last($rows)]['passed']) unlink($output);
}
file_put_contents($report, json_encode(['php' => PHP_VERSION, 'extensions' => get_loaded_extensions(), 'root' => $root, 'cases' => $rows], JSON_PRETTY_PRINT));
$failed = count(array_filter($rows, fn($r) => !$r['passed']));
echo json_encode(['total' => count($rows), 'failed' => $failed]), "\n";
exit($failed ? 1 : 0);
