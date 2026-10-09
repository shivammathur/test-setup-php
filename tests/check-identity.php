<?php
[$script, $branch, $arch, $ts] = $argv;
$expected = $branch === 'master' ? '8.7' : substr($branch, 4);
if (PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION !== $expected
    || PHP_INT_SIZE !== ($arch === 'x64' ? 8 : 4)
    || (bool) PHP_ZTS !== ($ts === 'ts')
    || !extension_loaded('zip')
    || ZipArchive::LIBZIP_VERSION !== '1.12'
    || php_ini_loaded_file() !== false) {
    throw new RuntimeException('PHP artifact identity or isolated configuration mismatch');
}
echo json_encode([
    'version' => PHP_VERSION,
    'arch' => $arch,
    'ts' => $ts,
    'libzip' => ZipArchive::LIBZIP_VERSION,
    'zstd_encode' => ZipArchive::isCompressionMethodSupported(ZipArchive::CM_ZSTD, true),
    'zstd_decode' => ZipArchive::isCompressionMethodSupported(ZipArchive::CM_ZSTD, false),
    'loaded_ini' => php_ini_loaded_file(),
], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
