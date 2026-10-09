<?php

function check(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

check(extension_loaded('zip'), 'The zip extension must load');
check(ZipArchive::LIBZIP_VERSION === '1.12', 'Expected libzip 1.12, got ' . ZipArchive::LIBZIP_VERSION);
$directory = sys_get_temp_dir() . '/libzip-qa-' . bin2hex(random_bytes(8));
check(mkdir($directory), 'Cannot create test directory');
$payload = str_repeat("libzip zstd round trip\0\xff\n", 4096);
$password = 'libzip-static-zstd-check';
$methods = [
    'store' => ZipArchive::CM_STORE,
    'deflate' => ZipArchive::CM_DEFLATE,
    'bzip2' => ZipArchive::CM_BZIP2,
    'lzma' => ZipArchive::CM_LZMA,
    'xz' => ZipArchive::CM_XZ,
    'zstd' => ZipArchive::CM_ZSTD,
];

foreach ($methods as $name => $method) {
    check(ZipArchive::isCompressionMethodSupported($method, true), "$name encoding unavailable");
    check(ZipArchive::isCompressionMethodSupported($method, false), "$name decoding unavailable");
    foreach ([false, true] as $encrypted) {
        $label = $name . ($encrypted ? '-aes256' : '-plain');
        $path = "$directory/$label.zip";
        $zip = new ZipArchive();
        check($zip->open($path, ZipArchive::CREATE | ZipArchive::OVERWRITE) === true, "$label open failed");
        check($zip->addFromString('payload.bin', $payload), "$label add failed");
        check($zip->setCompressionName('payload.bin', $method), "$label compression selection failed");
        check($zip->setMtimeName('payload.bin', 1700000000), "$label timestamp setting failed");
        if ($encrypted) {
            check($zip->setEncryptionName('payload.bin', ZipArchive::EM_AES_256, $password), "$label encryption selection failed");
        }
        check($zip->close(), "$label write failed");
        check($zip->open($path, ZipArchive::RDONLY) === true, "$label reopen failed");
        if ($encrypted) {
            check($zip->setPassword($password), "$label password setting failed");
        }
        $stat = $zip->statName('payload.bin');
        check(is_array($stat), "$label stat failed");
        check($stat['comp_method'] === $method, "$label compression method mismatch");
        check($stat['encryption_method'] === ($encrypted ? ZipArchive::EM_AES_256 : ZipArchive::EM_NONE), "$label encryption mismatch");
        check($stat['mtime'] === 1700000000, "$label timestamp mismatch");
        check($stat['size'] === strlen($payload), "$label size mismatch");
        if ($method !== ZipArchive::CM_STORE) {
            check($stat['comp_size'] < $stat['size'], "$label did not compress");
        }
        check($zip->getFromName('payload.bin') === $payload, "$label content mismatch");
        $stream = $zip->getStream('payload.bin');
        check(is_resource($stream), "$label stream open failed");
        check(stream_get_contents($stream) === $payload, "$label stream content mismatch");
        fclose($stream);
        check(!is_resource($stream), "$label stream was not closed");
        $extract = "$directory/$label";
        check($zip->extractTo($extract), "$label extraction failed");
        check(file_get_contents("$extract/payload.bin") === $payload, "$label extracted content mismatch");
        if ($encrypted) {
            check($zip->setPassword('wrong-password'), "$label wrong password setup failed");
            check(@$zip->getFromName('payload.bin') === false, "$label accepted a wrong password");
        }
        check($zip->close(), "$label read close failed");
        unlink("$extract/payload.bin");
        rmdir($extract);
        unlink($path);
        echo "$label: passed\n";
    }
}
if (defined('ZipArchive::AFL_WANT_TORRENTZIP')) {
    $input = "$directory/input.bin";
    $path = "$directory/torrent.zip";
    foreach ([false, true] as $replace) {
        $content = $replace ? 'replacement torrentzip payload' : 'original torrentzip payload';
        check(file_put_contents($input, $content) === strlen($content), 'TorrentZip input write failed');
        $zip = new ZipArchive();
        check($zip->open($path, $replace ? 0 : ZipArchive::CREATE | ZipArchive::OVERWRITE) === true, 'TorrentZip open failed');
        check($zip->setArchiveFlag(ZipArchive::AFL_WANT_TORRENTZIP, 1), 'TorrentZip flag setting failed');
        check($replace ? $zip->replaceFile($input, 0) : $zip->addFile($input, 'payload.bin'), 'TorrentZip add/replace failed');
        check($zip->close(), 'TorrentZip write failed');
        check($zip->open($path, ZipArchive::RDONLY) === true, 'TorrentZip reopen failed');
        check($zip->getArchiveFlag(ZipArchive::AFL_IS_TORRENTZIP) === 1, 'TorrentZip format mismatch');
        check($zip->getFromName('payload.bin') === $content, 'TorrentZip content mismatch');
        check($zip->close(), 'TorrentZip read close failed');
    }
    unlink($input);
    unlink($path);
    echo "torrentzip add/replace round trips: passed\n";
}
rmdir($directory);
echo 'libzip ', ZipArchive::LIBZIP_VERSION, ': all 12 PHP round trips passed', PHP_EOL;
