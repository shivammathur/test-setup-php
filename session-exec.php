<?php
function isSessionFd(int $fd, array $session): bool {
    $stream = @fopen("php://fd/$fd", "r");
    if (!$stream) {
        return false;
    }
    $stat = fstat($stream);
    fclose($stream);
    return $stat['dev'] === $session['dev'] && $stat['ino'] === $session['ino'];
}

if (($argv[1] ?? '') === 'after-exec') {
    if (isSessionFd((int) $argv[2], stat($argv[3]))) {
        throw new RuntimeException('Session file descriptor survived exec');
    }
    echo "Session file descriptor closed across exec\n";
    exit(0);
}

session_id('cloexec-check');
if (!session_start()) {
    throw new RuntimeException('Cannot start file-backed session');
}
$file = session_save_path() . '/sess_' . session_id();
$session = stat($file);
for ($fd = 3; $fd < 128; $fd++) {
    if (isSessionFd($fd, $session)) {
        echo "Session file open as fd $fd before exec\n";
        pcntl_exec(PHP_BINARY, ['-n', __FILE__, 'after-exec', (string) $fd, $file]);
        throw new RuntimeException('exec failed');
    }
}
throw new RuntimeException('Active session file descriptor missing');
