#!/usr/bin/env bash
set -euo pipefail

php -v
php -m | sort | tee "$RUNNER_TEMP/cache-audit/php-modules.txt"

php <<'PHP'
<?php
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
        fwrite(STDERR, "$extension extension is not loaded\n");
        exit(1);
    }
}

$curl = curl_version();
if (empty($curl['version']) || empty($curl['ssl_version'])) {
    fwrite(STDERR, "curl runtime check failed\n");
    exit(1);
}

$image = imagecreatetruecolor(8, 8);
if (!$image) {
    fwrite(STDERR, "gd runtime check failed\n");
    exit(1);
}
ob_start();
imagepng($image);
$png = ob_get_clean();
if ($png === false || strlen($png) === 0) {
    fwrite(STDERR, "gd PNG encode failed\n");
    exit(1);
}

$formatter = new IntlDateFormatter('en_US', IntlDateFormatter::SHORT, IntlDateFormatter::SHORT);
if (!$formatter->format(new DateTimeImmutable('2026-07-05 00:00:00 UTC'))) {
    fwrite(STDERR, "intl runtime check failed\n");
    exit(1);
}

$zip = new ZipArchive();
$zipPath = tempnam(sys_get_temp_dir(), 'zip-check-');
if ($zip->open($zipPath, ZipArchive::OVERWRITE) !== true || !$zip->addFromString('test.txt', 'ok') || !$zip->close()) {
    fwrite(STDERR, "zip runtime check failed\n");
    exit(1);
}

if (!class_exists(Imagick::class)) {
    fwrite(STDERR, "imagick class is missing\n");
    exit(1);
}

foreach (['PNG', 'JPEG', 'DJVU'] as $format) {
    if (!in_array($format, Imagick::queryFormats($format), true)) {
        fwrite(STDERR, "$format support is missing from ImageMagick\n");
        exit(1);
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
    fwrite(STDERR, "imagick runtime check failed\n");
    exit(1);
}

echo "runtime checks passed\n";
PHP
