<?php
declare(strict_types=1);
$cases = [];
function verify(bool $ok, string $name): void {
    global $cases;
    if (!$ok) { throw new RuntimeException($name); }
    $cases[] = $name;
}
verify(extension_loaded('zlib'), 'zlib loaded');
verify(ZLIB_VERSION === '1.3.2', 'zlib upstream version');
$seed = '';
for ($i = 0; $i < 4096; ++$i) { $seed .= hash('sha256', (string)$i, true); }
foreach ([0, 1, 31, 8191, 8192, 32768, 131072] as $length) {
    $data = substr($seed, 0, $length);
    foreach ([-1, 0, 1, 6, 9] as $level) {
        foreach ([['gzcompress', 'gzuncompress'], ['gzdeflate', 'gzinflate'], ['gzencode', 'gzdecode']] as [$encode, $decode]) {
            $compressed = $encode($data, $level);
            verify($decode($compressed) === $data, "$encode/$length/$level");
            verify(zlib_decode($compressed) === $data, "autodetect/$encode/$length/$level");
        }
    }
}
foreach ([ZLIB_ENCODING_RAW, ZLIB_ENCODING_DEFLATE, ZLIB_ENCODING_GZIP] as $encoding) {
    $deflater = deflate_init($encoding, ['level' => 6]);
    $compressed = '';
    foreach (str_split($seed, 997) as $part) { $compressed .= deflate_add($deflater, $part, ZLIB_SYNC_FLUSH); }
    $compressed .= deflate_add($deflater, '', ZLIB_FINISH);
    $inflater = inflate_init($encoding);
    $decoded = '';
    foreach (str_split($compressed, 433) as $part) { $decoded .= inflate_add($inflater, $part, ZLIB_SYNC_FLUSH); }
    verify($decoded === $seed, "incremental/$encoding");
    verify(inflate_get_status($inflater) === ZLIB_STREAM_END, "end-status/$encoding");
    verify(inflate_get_read_len($inflater) === strlen($compressed), "read-length/$encoding");
}
$file = tempnam(sys_get_temp_dir(), 'zqa');
try {
    $handle = gzopen($file, 'wb9');
    verify(is_resource($handle), 'gzip file open');
    foreach (str_split($seed, 8192) as $part) { verify(gzwrite($handle, $part) === strlen($part), 'gzip file chunk'); }
    verify(gzclose($handle), 'gzip close');
    verify(file_get_contents('compress.zlib://' . $file) === $seed, 'gzip stream wrapper');
    $handle = gzopen($file, 'rb');
    verify(gzseek($handle, 5000) === 0 && gztell($handle) === 5000, 'gzip seek');
    verify(gzread($handle, 6000) === substr($seed, 5000, 6000), 'gzip seek read');
    gzclose($handle);
} finally { unlink($file); }
$stream = fopen('php://temp', 'w+b');
$filter = stream_filter_append($stream, 'zlib.deflate', STREAM_FILTER_WRITE, ['window' => 15]);
fwrite($stream, $seed);
stream_filter_remove($filter);
rewind($stream);
verify(gzuncompress(stream_get_contents($stream)) === $seed, 'deflate stream filter');
fclose($stream);
verify(@gzuncompress('invalid') === false, 'invalid zlib rejection');
verify(@gzdecode('invalid') === false, 'invalid gzip rejection');
file_put_contents($argv[1], json_encode(['php' => PHP_VERSION, 'cases' => $cases, 'count' => count($cases), 'passed' => true], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
echo count($cases), " zlib checks passed\n";
