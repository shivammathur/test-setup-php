<?php
declare(strict_types=1);

function check(bool $condition, string $message): void {
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

check(extension_loaded('gd'), 'GD extension must load');
check(gd_info()['PNG Support'], 'PNG support must be enabled');
$checks = [];
foreach ([false, true] as $truecolor) {
    foreach ([false, true] as $interlaced) {
        foreach ([0, 6, 9] as $compression) {
            $image = $truecolor ? imagecreatetruecolor(11, 9) : imagecreate(11, 9);
            imagealphablending($image, false);
            imagesavealpha($image, true);
            imageinterlace($image, $interlaced);
            for ($y = 0; $y < 9; ++$y) {
                for ($x = 0; $x < 11; ++$x) {
                    $alpha = ($x + $y) % 3 === 0 ? 127 : (($x + $y) % 3 === 1 ? 64 : 0);
                    $color = imagecolorallocatealpha($image, $x * 23, $y * 29, ($x * 7 + $y * 11) % 256, $alpha);
                    imagesetpixel($image, $x, $y, $color);
                }
            }
            ob_start();
            check(imagepng($image, null, $compression), 'PNG encoding failed');
            $png = ob_get_clean();
            check(str_starts_with($png, "\x89PNG\r\n\x1a\n"), 'Invalid PNG signature');
            $decoded = imagecreatefromstring($png);
            check($decoded instanceof GdImage, 'PNG decoding failed');
            check(imagesx($decoded) === 11 && imagesy($decoded) === 9, 'Dimensions changed');
            for ($y = 0; $y < 9; ++$y) {
                for ($x = 0; $x < 11; ++$x) {
                    $want = imagecolorsforindex($image, imagecolorat($image, $x, $y));
                    $got = imagecolorsforindex($decoded, imagecolorat($decoded, $x, $y));
                    check($want === $got, "Pixel changed at $x,$y");
                }
            }
            $checks[] = ['truecolor' => $truecolor, 'interlaced' => $interlaced, 'compression' => $compression, 'pixels' => 99, 'png_sha256' => hash('sha256', $png)];
        }
    }
}
foreach (glob('libpng-src/contrib/testpngs/*.png') as $filename) {
    // The upstream valid fixtures cover grayscale, palette, alpha and 16-bit input.
    $image = @imagecreatefrompng($filename);
    check($image instanceof GdImage, "Cannot decode upstream fixture $filename");
    check(imagesx($image) > 0 && imagesy($image) > 0, "Invalid fixture dimensions $filename");
    $checks[] = ['fixture' => basename($filename), 'width' => imagesx($image), 'height' => imagesy($image)];
}
check(@imagecreatefromstring("\x89PNG\r\n\x1a\ntruncated") === false, 'Malformed input must be rejected');
echo json_encode(['php' => PHP_VERSION, 'bits' => PHP_INT_SIZE * 8, 'zts' => (bool) PHP_ZTS, 'checks' => $checks], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
