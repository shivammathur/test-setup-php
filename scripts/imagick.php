<?php
if (!extension_loaded('imagick')) {
    throw new Exception('Imagick is not loaded');
}
$formats = array('PNG', 'JPEG');
$checks = array();
foreach ($formats as $format) {
    if (count(Imagick::queryFormats($format)) === 0) {
        throw new Exception('Missing image format: ' . $format);
    }
    $image = new Imagick();
    $image->newImage(16, 12, 'white');
    $image->setImageFormat($format);
    $blob = $image->getImageBlob();
    if (strlen($blob) === 0) {
        throw new Exception('Empty encoded image: ' . $format);
    }
    $decoded = new Imagick();
    $decoded->readImageBlob($blob);
    if ($decoded->getImageWidth() !== 16 || $decoded->getImageHeight() !== 12) {
        throw new Exception('Image round-trip dimensions differ');
    }
    $decoded->resizeImage(8, 6, Imagick::FILTER_LANCZOS, 1);
    if ($decoded->getImageWidth() !== 8 || $decoded->getImageHeight() !== 6) {
        throw new Exception('Image resize failed');
    }
    $file = tempnam(sys_get_temp_dir(), 'php5-imagick-');
    if ($file === false || !$decoded->writeImage($file)) {
        throw new Exception('Image file write failed');
    }
    $fromFile = new Imagick($file);
    if ($fromFile->getImageWidth() !== 8 || $fromFile->getImageHeight() !== 6) {
        throw new Exception('Image file round-trip failed');
    }
    $fromFile->clear();
    unlink($file);
    $checks[$format] = array('encoded_bytes' => strlen($blob), 'roundtrip' => true, 'resize' => true, 'file_roundtrip' => true);
    $decoded->clear();
    $image->clear();
}
$available = Imagick::queryFormats('*');
sort($available, SORT_STRING);
echo json_encode(array('version' => Imagick::getVersion(), 'formats' => $available, 'checks' => $checks)) . "\n";
