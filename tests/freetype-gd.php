<?php
function test_freetype_gd(): void
{
    $info = gd_info();
    assert_true($info['FreeType Support'] ?? false, 'GD must include FreeType');
    $report = getenv('WINLIBS_QA_REPORT_DIR');
    $rows = [];
    $found = 0;
    foreach (['arial.ttf', 'times.ttf', 'segoeui.ttf', 'comic.ttf', 'calibri.ttf'] as $name) {
        $font = getenv('WINDIR') . '/Fonts/' . $name;
        if (!is_file($font)) continue;
        $found++;
        foreach ([9, 18, 36] as $size) {
            foreach ([0, 15, 90] as $angle) {
                foreach (['AVATAR fi ffi 0123', 'Grüße Ελληνικά Кириллица'] as $text) {
                    $box = imagettfbbox($size, $angle, $font, $text);
                    assert_true(is_array($box) && count($box) === 8, 'TrueType bounding box must contain eight coordinates');
                    assert_same($box, imageftbbox($size, $angle, $font, $text), 'FreeType and TrueType bbox aliases must agree');
                    $xs = [$box[0], $box[2], $box[4], $box[6]];
                    $ys = [$box[1], $box[3], $box[5], $box[7]];
                    $width = max($xs) - min($xs) + 40;
                    $height = max($ys) - min($ys) + 40;
                    assert_true($width > 40 && $width < 4096 && $height > 40 && $height < 4096, 'Text dimensions must be reasonable');
                    $a = imagecreatetruecolor($width, $height);
                    $b = imagecreatetruecolor($width, $height);
                    imagefill($a, 0, 0, 0xffffff);
                    imagefill($b, 0, 0, 0xffffff);
                    $x = 20 - min($xs); $y = 20 - min($ys);
                    $drawA = imagettftext($a, $size, $angle, $x, $y, 0, $font, $text);
                    $drawB = imagefttext($b, $size, $angle, $x, $y, 0, $font, $text);
                    assert_same($drawA, $drawB, 'Text drawing aliases must return matching coordinates');
                    ob_start(); imagepng($a); $pngA = ob_get_clean();
                    ob_start(); imagepng($b); $pngB = ob_get_clean();
                    assert_same($pngA, $pngB, 'Text drawing aliases must render identical pixels');
                    $pixels = 0;
                    for ($py = 0; $py < $height; $py++) {
                        for ($px = 0; $px < $width; $px++) {
                            if (imagecolorat($a, $px, $py) !== 0xffffff) $pixels++;
                        }
                    }
                    assert_true($pixels > 0, 'Text must produce visible pixels');
                    $rows[] = ['font' => $name, 'size' => $size, 'angle' => $angle, 'text' => $text, 'box' => $box,
                        'width' => $width, 'height' => $height, 'pixels' => $pixels, 'png_sha256' => hash('sha256', $pngA)];
                    if ($size === 18 && $angle === 0) file_put_contents($report . '/' . $name . '-' . count($rows) . '.png', $pngA);
                }
            }
        }
    }
    assert_at_least(3, $found, 'At least three Windows fonts must be tested');
    file_put_contents($report . '/freetype-gd.json', json_encode($rows, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
    suite_info(count($rows) . ' GD font/size/rotation/unicode combinations passed');
}
