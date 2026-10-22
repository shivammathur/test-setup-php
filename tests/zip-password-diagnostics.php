<?php
declare(strict_types=1);
error_reporting(E_ALL);
$report = $argv[1];
$dir = sys_get_temp_dir() . '/zip-password-' . bin2hex(random_bytes(8));
mkdir($dir);
$payload = str_repeat("libzip\0binary\xff\r\n", 4096);
$rows = [];
$methods = ['store' => ZipArchive::CM_STORE, 'deflate' => ZipArchive::CM_DEFLATE,
    'bzip2' => ZipArchive::CM_BZIP2, 'lzma' => ZipArchive::CM_LZMA,
    'xz' => ZipArchive::CM_XZ, 'zstd' => ZipArchive::CM_ZSTD];
foreach ($methods as $name => $method) {
    $path = "$dir/$name.zip";
    $z = new ZipArchive;
    if ($z->open($path, ZipArchive::CREATE) !== true ||
        !$z->addFromString('payload', $payload) || !$z->setCompressionName('payload', $method) ||
        !$z->setEncryptionName('payload', ZipArchive::EM_TRAD_PKWARE, 'correct-password') || !$z->close()) {
        throw new RuntimeException('Fixture creation failed');
    }
    $row = ['method' => $name, 'attempts' => 0, 'falseReturns' => 0, 'collisions' => [], 'leakedPlaintext' => false];
    for ($i = 0; $i < 4096 && count($row['collisions']) < 8; $i++) {
        $z = new ZipArchive;
        if ($z->open($path, ZipArchive::RDONLY) !== true || !$z->setPassword("incorrect-password-$i")) {
            throw new RuntimeException('Fixture reopen failed');
        }
        $warnings = [];
        set_error_handler(function ($severity, $message) use (&$warnings) { $warnings[] = $message; return true; });
        $wrong = $z->getFromIndex(0);
        $row['attempts']++;
        if ($wrong === false) { $row['falseReturns']++; }
        else {
            $stream = $z->getStream('payload');
            $streamResult = is_resource($stream) ? stream_get_contents($stream) : false;
            if (is_resource($stream)) { fclose($stream); }
            $row['collisions'][] = ['passwordIndex' => $i, 'type' => get_debug_type($wrong),
                'length' => strlen($wrong), 'sha256' => hash('sha256', $wrong),
                'status' => $z->status, 'statusString' => $z->getStatusString(),
                'streamType' => get_debug_type($streamResult),
                'streamLength' => is_string($streamResult) ? strlen($streamResult) : null,
                'warnings' => $warnings];
            $row['leakedPlaintext'] = $row['leakedPlaintext'] || $wrong === $payload || $streamResult === $payload;
        }
        restore_error_handler();
        $z->setPassword('correct-password');
        if ($z->getFromIndex(0) !== $payload || !$z->close()) { throw new RuntimeException('Correct-password read failed'); }
    }
    $rows[] = $row;
}
file_put_contents($report, json_encode(['php' => PHP_VERSION, 'libzip' => ZipArchive::LIBZIP_VERSION,
    'rows' => $rows], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
foreach ($rows as $row) { if ($row['leakedPlaintext']) { throw new RuntimeException('Wrong password returned plaintext'); } }
echo json_encode(['libzip' => ZipArchive::LIBZIP_VERSION, 'attempts' => array_sum(array_column($rows, 'attempts')),
    'collisions' => array_sum(array_map(fn($r) => count($r['collisions']), $rows))]), "\n";
