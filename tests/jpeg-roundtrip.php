<?php
declare(strict_types=1);

$results = [];
function check(bool $ok, string $name): void {
    global $results;
    $results[] = ['name' => $name, 'passed' => $ok];
    if (!$ok) {
        throw new RuntimeException($name);
    }
}
set_error_handler(static function (int $severity, string $message, string $file, int $line): never {
    throw new ErrorException($message, 0, $severity, $file, $line);
});

try {
    check(extension_loaded('gd'), 'GD loads');
    check((gd_info()['JPEG Support'] ?? false) === true, 'JPEG support is enabled');
    check((imagetypes() & IMG_JPG) !== 0, 'JPEG appears in supported image types');
    $dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'jpeg-321-' . getmypid();
    if (!is_dir($dir)) mkdir($dir);
    foreach ([[1, 1], [1, 33], [2, 17], [17, 2], [31, 33], [128, 65]] as [$width, $height]) {
        foreach ([false, true] as $progressive) {
            $name = "{$width}x{$height}-" . ($progressive ? 'progressive' : 'baseline');
            $im = imagecreatetruecolor($width, $height);
            check($im instanceof GdImage, "$name image created");
            $red = imagecolorallocate($im, 240, 32, 16);
            imagefill($im, 0, 0, $red);
            imageinterlace($im, $progressive);
            ob_start();
            $encoded = imagejpeg($im, null, 95);
            $data = ob_get_clean();
            check($encoded && is_string($data) && strlen($data) > 100, "$name encoded");
            check(str_starts_with($data, "\xff\xd8") && str_ends_with($data, "\xff\xd9"), "$name JPEG markers");
            $meta = getimagesizefromstring($data);
            check($meta[0] === $width && $meta[1] === $height && $meta[2] === IMAGETYPE_JPEG, "$name metadata");
            $file = $dir . DIRECTORY_SEPARATOR . "$name.jpg";
            file_put_contents($file, $data);
            foreach (['file' => imagecreatefromjpeg($file), 'memory' => imagecreatefromstring($data)] as $mode => $decoded) {
                check($decoded instanceof GdImage, "$name $mode decoded");
                check(imagesx($decoded) === $width && imagesy($decoded) === $height, "$name $mode dimensions");
                foreach ([[0, 0], [$width - 1, $height - 1]] as [$x, $y]) {
                    $pixel = imagecolorsforindex($decoded, imagecolorat($decoded, $x, $y));
                    check(abs($pixel['red'] - 240) <= 3 && abs($pixel['green'] - 32) <= 3 && abs($pixel['blue'] - 16) <= 3, "$name $mode pixel $x,$y");
                }
                $scaled = imagescale($decoded, 8, 8);
                check($scaled instanceof GdImage && imagesx($scaled) === 8 && imagesy($scaled) === 8, "$name $mode scaling");
                $png = $dir . DIRECTORY_SEPARATOR . "$name-$mode.png";
                check(imagepng($decoded, $png), "$name $mode PNG transcode");
                $back = imagecreatefrompng($png);
                check($back instanceof GdImage && imagesx($back) === $width && imagesy($back) === $height, "$name $mode PNG dimensions");
                unlink($png);
            }
            unlink($file);
        }
    }
    $gradient = imagecreatetruecolor(67, 45);
    for ($y = 0; $y < 45; $y++) {
        for ($x = 0; $x < 67; $x++) imagesetpixel($gradient, $x, $y, (($x * 3) << 16) | (($y * 5) << 8) | (($x + $y) * 2));
    }
    foreach ([0, 25, 75, 100] as $quality) {
        ob_start();
        check(imagejpeg($gradient, null, $quality), "gradient quality $quality encoded");
        $data = ob_get_clean();
        $decoded = imagecreatefromstring($data);
        check($decoded instanceof GdImage && imagesx($decoded) === 67 && imagesy($decoded) === 45, "gradient quality $quality decoded");
    }
    $palette = imagecreate(19, 23);
    imagecolorallocate($palette, 10, 90, 180);
    ob_start();
    check(imagejpeg($palette, null, 90), 'palette image converted to JPEG');
    $decoded = imagecreatefromstring(ob_get_clean());
    check($decoded instanceof GdImage && imagesx($decoded) === 19 && imagesy($decoded) === 23, 'palette JPEG decoded');
    rmdir($dir);
    $report = ['php' => PHP_VERSION, 'zts' => PHP_ZTS, 'bits' => PHP_INT_SIZE * 8, 'forced_scalar_environment' => getenv('JSIMD_FORCENONE') === '1', 'gd' => gd_info(), 'passed' => true, 'cases' => $results];
    echo json_encode($report, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
} catch (Throwable $e) {
    echo json_encode(['passed' => false, 'error' => $e->getMessage(), 'cases' => $results], JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), "\n";
    exit(1);
}
