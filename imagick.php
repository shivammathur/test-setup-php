<?php
$root = sys_get_temp_dir() . '/imagick-release-' . getmypid();
mkdir($root);
$image = new Imagick();
$image->newImage(16, 16, 'white');
$draw = new ImagickDraw();
$fonts = Imagick::queryFonts('*');
if (!$fonts) { throw new Exception('No fonts available'); }
$draw->setFont($fonts[0]);
$draw->setFontSize(8);
$draw->setFillColor('black');
$image->annotateImage($draw, 1, 10, 0, 'PHP');
foreach (array('PNG', 'JPEG', 'TIFF', 'WEBP', 'PDF') as $format) {
    $image->setImageFormat($format);
    $file = $root . '/test.' . strtolower($format);
    $image->writeImage($file);
    $read = new Imagick($file);
    if ($read->getImageWidth() < 1) { throw new Exception('Cannot read ' . $format); }
    $read->clear();
    unlink($file);
    echo $format, " roundtrip passed\n";
}
$formats = Imagick::queryFormats('HEI*');
if (!in_array('HEIC', $formats, true) && !in_array('HEIF', $formats, true)) {
    throw new Exception('HEIC/HEIF support missing');
}
$image->clear();
rmdir($root);
?>
