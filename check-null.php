<?php
$results = [];
$failed = false;
foreach (['array', 'shell'] as $mode) {
    foreach (range(0, 3) as $fd) {
        $descriptors = [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
        foreach ($fd === 3 ? range(0, 2) : [$fd] as $nullFd) {
            $descriptors[$nullFd] = ['null'];
        }
        $exe = __DIR__ . DIRECTORY_SEPARATOR . 'null-probe.exe';
        $command = $mode === 'array' ? [$exe, (string) $fd] : '"' . $exe . '" ' . $fd;
        $process = proc_open($command, $descriptors, $pipes);
        if (!is_resource($process)) {
            throw new RuntimeException('proc_open failed');
        }
        $output = [];
        foreach ($pipes as $pipeFd => $pipe) {
            if ($pipeFd !== 0) $output[$pipeFd] = stream_get_contents($pipe);
            fclose($pipe);
        }
        $exit = proc_close($process);
        $results[] = ['mode' => $mode, 'null' => $fd === 3 ? 'all' : $fd, 'exit' => $exit, 'output' => $output];
        $failed |= $exit !== 0;
    }
}
echo json_encode($results, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
exit($failed ? 1 : 0);
