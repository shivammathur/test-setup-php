<?php
$root = __DIR__ . '/server-docroot';
@mkdir($root);
file_put_contents($root . '/index.php', '<?php echo "ok";');
$result = ['started'=>0, 'failures'=>[]];
for ($i=0; $i<(int)$argv[1]; $i++) {
    $log = tempnam(sys_get_temp_dir(), 'server-probe-');
    $fd = fopen($log, 'ab');
    $cmd = [PHP_BINARY, '-n', '-d', 'opcache.enable_cli=0', '-t', $root, '-S', 'localhost:0'];
    $p = proc_open($cmd, [0=>STDIN, 1=>$fd, 2=>$fd], $pipes, $root);
    $output = ''; $ready = false; $status = null;
    for ($try=0; $try<100; $try++) {
        usleep(10000);
        $status = proc_get_status($p);
        $output = file_get_contents($log);
        if (!$status['running']) break;
        if (str_contains($output, ') started')) { $ready = true; break; }
    }
    if ($ready) $result['started']++;
    else {
        $event = ['iteration'=>$i, 'status'=>$status, 'output'=>$output];
        $result['failures'][] = $event;
        fwrite(STDERR, json_encode($event)."\n");
    }
    if ($status['running']) proc_terminate($p);
    proc_close($p); fclose($fd); @unlink($log);
}
echo json_encode($result), "\n";
