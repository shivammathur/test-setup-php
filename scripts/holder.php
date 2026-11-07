<?php
[$script, $marker, $ready, $stop] = $argv;
if (!opcache_compile_file($marker)) {
    throw new RuntimeException('Could not cache the reattachment marker');
}
file_put_contents($ready, 'ready');
$deadline = microtime(true) + 180;
while (!file_exists($stop) && microtime(true) < $deadline) {
    usleep(10000);
}
echo "HOLDER_DONE\n";
