<?php

function ok(bool $condition, string $message): void {
    if (!$condition) {
        fwrite(STDERR, "not ok - {$message}\n");
        exit(1);
    }
    echo "ok - {$message}\n";
}

function temp_path(string $name): string {
    $dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'gd-artifact-' . getmypid();
    if (!is_dir($dir)) {
        mkdir($dir, 0777, true);
    }
    return $dir . DIRECTORY_SEPARATOR . $name;
}

function contains_any(string $payload, array $needles): bool {
    foreach ($needles as $needle) {
        if (stripos($payload, $needle) !== false) {
            return true;
        }
    }
    return false;
}

ok(extension_loaded('gd'), 'gd extension is loaded');
ok(function_exists('gd_info'), 'gd_info is available');
ok(function_exists('imageavif'), 'imageavif is available');
ok(function_exists('imagecreatefromavif'), 'imagecreatefromavif is available');

$info = gd_info();
ok(is_array($info) && !empty($info['GD Version']), 'gd_info reports a GD version');
ok(($info['PNG Support'] ?? false) === true, 'PNG support is enabled');
ok(($info['JPEG Support'] ?? false) === true, 'JPEG support is enabled');
ok(($info['AVIF Support'] ?? false) === true, 'AVIF support is enabled');
ok(defined('IMG_AVIF') && ((imagetypes() & IMG_AVIF) === IMG_AVIF), 'imagetypes includes AVIF');

$image = imagecreatetruecolor(16, 16);
ok($image instanceof GdImage, 'imagecreatetruecolor creates a GdImage');
imagesavealpha($image, true);
$background = imagecolorallocatealpha($image, 0, 0, 0, 127);
imagefill($image, 0, 0, $background);
for ($i = 0; $i < 16; $i++) {
    $color = imagecolorallocate($image, 16 * $i, 255 - 8 * $i, 64 + 4 * $i);
    imageline($image, 0, $i, 15, 15 - $i, $color);
}

ob_start();
$encoded = imageavif($image, null, 80, 6);
$avif = ob_get_clean();
ok($encoded === true && strlen($avif) > 32, 'imageavif emits an AVIF payload');

$avifPath = temp_path('roundtrip.avif');
file_put_contents($avifPath, $avif);
$decoded = imagecreatefromavif($avifPath);
ok($decoded instanceof GdImage, 'imagecreatefromavif decodes the emitted AVIF payload');
ok(imagesx($decoded) === 16 && imagesy($decoded) === 16, 'decoded AVIF dimensions match');

$fromString = imagecreatefromstring($avif);
ok($fromString instanceof GdImage, 'imagecreatefromstring detects and decodes AVIF');

$gdDll = getenv('PHP_GD_DLL') ?: ini_get('extension_dir') . DIRECTORY_SEPARATOR . 'php_gd.dll';
ok(is_file($gdDll), 'php_gd.dll is available for artifact inspection');
$payload = file_get_contents($gdDll);
ok(is_string($payload) && strlen($payload) > 0, 'php_gd.dll payload is readable');

$markers = [
    'libheif' => ['libheif', 'heif_image_create', 'HEIF (ISO/IEC'],
    'libjxl' => ['JXL_FAILURE', 'ftypjxl', 'lib/jxl'],
    'libtiff' => ['TIFF', 'libtiff'],
    'libultrahdr' => ['UHDR_IMG_FMT', 'uhdr_encode', 'ultrahdr'],
];

foreach ($markers as $library => $needles) {
    ok(contains_any($payload, $needles), "{$library} static payload marker is present in php_gd.dll");
}

echo "gd artifact smoke test complete\n";
