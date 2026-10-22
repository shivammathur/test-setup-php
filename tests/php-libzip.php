<?php
declare(strict_types=1);
error_reporting(E_ALL);
$report = $argv[1];
$root = sys_get_temp_dir() . '/libzip-qa-' . bin2hex(random_bytes(8));
mkdir($root);
chdir($root);
$results = [];
function check(bool $ok, string $message): void {
    if (!$ok) { throw new RuntimeException($message); }
}
function runCase(string $name, callable $test): void {
    global $results;
    try { $test(); $results[] = ['case' => $name, 'passed' => true]; }
    catch (Throwable $e) { $results[] = ['case' => $name, 'passed' => false, 'error' => (string)$e]; }
}
function openZip(string $path, int $flags = 0): ZipArchive {
    $z = new ZipArchive;
    check($z->open($path, $flags) === true, "open $path");
    return $z;
}
runCase('version and complete API manifest', function () {
    check(ZipArchive::LIBZIP_VERSION === '1.12.1', 'libzip runtime version');
    $manifest = json_decode(file_get_contents(__DIR__ . '/../zip-api.json'), true, flags: JSON_THROW_ON_ERROR);
    $branch = PHP_VERSION_ID >= 80700 ? 'master' : 'PHP-' . PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;
    $actual = get_class_methods(ZipArchive::class); sort($actual);
    check($actual === $manifest[$branch], 'ZipArchive public methods differ from complete source stub');
});
$methods = ['store' => ZipArchive::CM_STORE, 'deflate' => ZipArchive::CM_DEFLATE,
    'bzip2' => ZipArchive::CM_BZIP2, 'lzma' => ZipArchive::CM_LZMA,
    'xz' => ZipArchive::CM_XZ, 'zstd' => ZipArchive::CM_ZSTD];
$encryption = ['none' => ZipArchive::EM_NONE, 'traditional' => ZipArchive::EM_TRAD_PKWARE,
    'aes128' => ZipArchive::EM_AES_128, 'aes192' => ZipArchive::EM_AES_192, 'aes256' => ZipArchive::EM_AES_256];
foreach ($methods as $methodName => $method) {
    foreach ($encryption as $encryptionName => $enc) {
        runCase("$methodName/$encryptionName round trip", function () use ($methodName, $method, $encryptionName, $enc) {
            check(ZipArchive::isCompressionMethodSupported($method, true) && ZipArchive::isCompressionMethodSupported($method, false), 'compression support');
            check(ZipArchive::isEncryptionMethodSupported($enc, true) && ZipArchive::isEncryptionMethodSupported($enc, false), 'encryption support');
            $path = "$methodName-$encryptionName.zip";
            $payload = str_repeat("libzip\0binary\xff\r\n", 4096);
            $z = openZip($path, ZipArchive::CREATE | ZipArchive::OVERWRITE);
            check($z->addFromString('dir/payload.bin', $payload), 'add payload');
            check($z->setCompressionName('dir/payload.bin', $method), 'compression setup');
            check($z->setEncryptionName('dir/payload.bin', $enc, 'correct-password'), 'encryption setup');
            check($z->setMtimeName('dir/payload.bin', 1700000000), 'mtime setup');
            check($z->setCommentName('dir/payload.bin', 'binary round trip'), 'file comment');
            check($z->close(), 'close write');
            $z = openZip($path, ZipArchive::RDONLY);
            $st = $z->statIndex(0);
            check($st['size'] === strlen($payload) && $st['comp_method'] === $method && $st['encryption_method'] === $enc && $st['mtime'] === 1700000000, 'entry metadata');
            if ($enc !== ZipArchive::EM_NONE) {
                check($z->setPassword('incorrect-password'), 'wrong password setup');
                check(@$z->getFromIndex(0) === false, 'wrong password rejected');
            }
            check($z->setPassword('correct-password'), 'password setup');
            check($z->getFromName('dir/payload.bin') === $payload, 'name read');
            check($z->getFromIndex(0) === $payload, 'index read');
            $stream = $z->getStream('dir/payload.bin');
            check(is_resource($stream) && stream_get_contents($stream) === $payload, 'stream read');
            fclose($stream);
            check($z->getCommentIndex(0) === 'binary round trip', 'comment read');
            check($z->close(), 'close read');
        });
    }
}
runCase('file slices replacement rename delete and extraction', function () {
    file_put_contents('source.bin', '0123456789');
    $z = openZip('mutations.zip', ZipArchive::CREATE);
    check($z->addFile('source.bin', 'slice.txt', 2, 4), 'file slice');
    check($z->addFromString('remove.txt', 'removed'), 'add deleted entry');
    check($z->addEmptyDir('dir') && $z->addFromString('dir/data.txt', 'retained'), 'directory');
    check($z->setArchiveComment('archive-comment'), 'archive comment');
    check($z->close(), 'initial close');
    $z = openZip('mutations.zip');
    check($z->getFromName('slice.txt') === '2345', 'slice contents');
    check($z->replaceFile('source.bin', $z->locateName('slice.txt'), 5, 3), 'replace slice');
    check($z->renameName('slice.txt', 'renamed.txt'), 'rename');
    check($z->deleteName('remove.txt'), 'delete');
    check($z->setExternalAttributesName('renamed.txt', ZipArchive::OPSYS_UNIX, 0644 << 16), 'attributes');
    check($z->close(), 'mutation close');
    $z = openZip('mutations.zip');
    check($z->getFromName('renamed.txt') === '567' && $z->locateName('remove.txt') === false, 'mutation persisted');
    check($z->getArchiveComment() === 'archive-comment', 'archive comment persisted');
    check($z->getExternalAttributesName('renamed.txt', $opsys, $attr) && $opsys === ZipArchive::OPSYS_UNIX && (($attr >> 16) & 0777) === 0644, 'attributes persisted');
    check($z->extractTo('extracted'), 'extract');
    check(file_get_contents('extracted/renamed.txt') === '567' && file_get_contents('extracted/dir/data.txt') === 'retained', 'extracted bytes');
    check($z->close(), 'close extracted');
});
runCase('progress callback and cancellation', function () {
    $z = openZip('progress.zip', ZipArchive::CREATE);
    $progress = 0;
    check($z->registerProgressCallback(0.01, function (float $state) use (&$progress) { check($state >= 0 && $state <= 1, 'progress range'); $progress++; }), 'register progress');
    check($z->registerCancelCallback(fn() => 0), 'register noncancel');
    check($z->addFromString('data', str_repeat('progress', 10000)), 'add progress');
    check($z->close() && $progress > 0, 'progress observed');
    $z = openZip('cancel.zip', ZipArchive::CREATE);
    check($z->registerCancelCallback(fn() => 1), 'register cancel');
    check($z->addFromString('data', str_repeat('cancel', 10000)), 'add cancelled');
    check(@$z->close() === false && $z->status === ZipArchive::ER_CANCELLED, 'cancelled close status');
});
runCase('ZIP64 entry count', function () {
    $z = openZip('zip64.zip', ZipArchive::CREATE);
    for ($i = 0; $i < 65536; $i++) { check($z->addFromString("entry-$i", ''), 'ZIP64 add'); }
    check($z->close(), 'ZIP64 close');
    $z = openZip('zip64.zip', ZipArchive::CHECKCONS);
    check(count($z) === 65536 && $z->getNameIndex(65535) === 'entry-65535', 'ZIP64 directory');
    check($z->close(), 'ZIP64 read close');
});
runCase('invalid and truncated archive rejection', function () {
    file_put_contents('invalid.zip', 'not a zip file');
    $z = new ZipArchive;
    check($z->open('invalid.zip') !== true, 'invalid archive rejected');
    $bytes = file_get_contents('mutations.zip');
    file_put_contents('truncated.zip', substr($bytes, 0, 40));
    check($z->open('truncated.zip', ZipArchive::CHECKCONS) !== true, 'truncated archive rejected');
});
if (PHP_VERSION_ID >= 80300) {
    runCase('TorrentZip creation addition and replacement regression', function () {
        $z = openZip('torrent.zip', ZipArchive::CREATE);
        check($z->setArchiveFlag(ZipArchive::AFL_WANT_TORRENTZIP, 1), 'TorrentZip flag');
        check($z->addFromString('payload.txt', 'original'), 'TorrentZip add');
        check($z->close(), 'TorrentZip close');
        $z = openZip('torrent.zip');
        check($z->getArchiveFlag(ZipArchive::AFL_IS_TORRENTZIP) === 1, 'TorrentZip recognized');
        check($z->setArchiveFlag(ZipArchive::AFL_WANT_TORRENTZIP, 1), 'TorrentZip preserve');
        check($z->addFromString('payload.txt', 'replacement'), 'TorrentZip replacement');
        check($z->addFromString('new.txt', 'new-file'), 'TorrentZip addition');
        check($z->close(), 'TorrentZip update close');
        $z = openZip('torrent.zip');
        check($z->getArchiveFlag(ZipArchive::AFL_IS_TORRENTZIP) === 1, 'updated TorrentZip recognized');
        check($z->getFromName('payload.txt') === 'replacement' && $z->getFromName('new.txt') === 'new-file', 'TorrentZip updated bytes');
        check($z->close(), 'TorrentZip read close');
    });
}
if (PHP_VERSION_ID >= 80600) {
    runCase('memory archive openString and closeString', function () {
        $z = new ZipArchive;
        check($z->openString('', ZipArchive::CREATE) === true, 'create memory archive');
        check($z->addFromString('memory.txt', 'memory round trip'), 'memory add');
        $bytes = $z->closeString();
        check(is_string($bytes) && strlen($bytes) > 0, 'memory export');
        $r = new ZipArchive;
        check($r->openString($bytes, ZipArchive::RDONLY) === true, 'memory reopen');
        check($r->getFromName('memory.txt') === 'memory round trip', 'memory bytes');
        check($r->close(), 'memory close');
    });
}
$failures = array_values(array_filter($results, fn($r) => !$r['passed']));
file_put_contents($report, json_encode(['php' => PHP_VERSION, 'libzip' => ZipArchive::LIBZIP_VERSION, 'cases' => $results, 'failures' => count($failures)], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
echo json_encode(['cases' => count($results), 'failures' => $failures], JSON_PRETTY_PRINT), "\n";
exit($failures ? 1 : 0);
