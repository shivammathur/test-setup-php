#!/usr/bin/env bash
set -euo pipefail

php -v
php -m | sort | tee "$RUNNER_TEMP/cache-audit/php-modules.txt"

php <<'PHP'
<?php
$stderr = fopen('php://stderr', 'w');

function fail($message) {
    global $stderr;

    fwrite($stderr, $message . "\n");
    exit(1);
}

$extensions = [
    'curl',
    'gd',
    'imagick',
    'intl',
    'mbstring',
    'mysqli',
    'pdo_mysql',
    'pdo_pgsql',
    'zip',
];

foreach ($extensions as $extension) {
    if (!extension_loaded($extension)) {
        fail("$extension extension is not loaded");
    }
}

$curl = curl_version();
if (empty($curl['version']) || empty($curl['ssl_version'])) {
    fail("curl runtime check failed");
}

$image = imagecreatetruecolor(8, 8);
if (!$image) {
    fail("gd runtime check failed");
}
ob_start();
if (!function_exists('imagepng') || !imagepng($image)) {
    $gd = function_exists('gd_info') ? gd_info() : [];
    fail('gd PNG encode failed; gd_info=' . json_encode($gd));
}
$png = ob_get_clean();
if ($png === false || strlen($png) === 0) {
    $gd = function_exists('gd_info') ? gd_info() : [];
    fail('gd PNG output was empty; gd_info=' . json_encode($gd));
}
imagedestroy($image);

$formatter = new IntlDateFormatter('en_US', IntlDateFormatter::SHORT, IntlDateFormatter::SHORT);
if (!$formatter->format(new DateTime('2026-07-05 00:00:00 UTC'))) {
    fail("intl runtime check failed");
}

$zip = new ZipArchive();
$zipPath = tempnam(sys_get_temp_dir(), 'zip-check-');
if ($zip->open($zipPath, ZipArchive::OVERWRITE) !== true || !$zip->addFromString('test.txt', 'ok') || !$zip->close()) {
    fail("zip runtime check failed");
}

if (!class_exists('Imagick')) {
    fail("imagick class is missing");
}

foreach (['PNG', 'JPEG', 'DJVU'] as $format) {
    if (!in_array($format, Imagick::queryFormats($format), true)) {
        fail("$format support is missing from ImageMagick");
    }
}

$imagick = new Imagick();
$imagick->newImage(32, 32, new ImagickPixel('red'));
$imagick->setImageFormat('png');
$blob = $imagick->getImagesBlob();

$roundtrip = new Imagick();
$roundtrip->readImageBlob($blob);
$roundtrip->resizeImage(16, 16, Imagick::FILTER_LANCZOS, 1);
$roundtrip->setImageFormat('jpeg');
$jpeg = $roundtrip->getImagesBlob();
if ($roundtrip->getImageWidth() !== 16 || $roundtrip->getImageHeight() !== 16 || strlen($jpeg) === 0) {
    fail("imagick runtime check failed");
}

echo "runtime checks passed\n";
PHP
