<?php
$prefix = $argv[1];
$result = [
    'php' => PHP_VERSION,
    'zend_assertions' => ini_get('zend.assertions'),
    'imagick' => phpversion('imagick'),
    'imagemagick' => Imagick::getVersion(),
    'avif_formats' => Imagick::queryFormats('AVIF'),
    'heic_formats' => Imagick::queryFormats('HEIC'),
];
try {
    $image = new Imagick();
    $image->newImage(16, 16, 'red');
    $image->setImageFormat('AVIF');
    $blob = $image->getImageBlob();
    if (strlen($blob) === 0) {
        throw new RuntimeException('Empty encoded AVIF');
    }
    file_put_contents($prefix . '.avif', $blob);
    $result['bytes'] = strlen($blob);
    $result['ftyp'] = bin2hex(substr($blob, 0, 32));
    if (substr($blob, 4, 4) !== 'ftyp' || !preg_match('/avif|avis/', substr($blob, 8, 40))) {
        throw new RuntimeException('Output is not an AVIF container');
    }
    $decoded = new Imagick();
    $decoded->readImageBlob($blob);
    $result['decoded_format'] = $decoded->getImageFormat();
    $result['dimensions'] = [$decoded->getImageWidth(), $decoded->getImageHeight()];
    if ($result['dimensions'] !== [16, 16]) {
        throw new RuntimeException('Decoded dimensions differ');
    }
    $result['decoded_colorspace'] = $decoded->getImageColorspace();
    $decoded->transformImageColorspace(Imagick::COLORSPACE_SRGB);
    $result['pixel'] = $decoded->getImagePixelColor(0, 0)->getColor();
    $pixel = $result['pixel'];
    if ($pixel['r'] < 230 || $pixel['g'] > 25 || $pixel['b'] > 25) {
        throw new RuntimeException('Decoded pixel is not red');
    }
    $result['ok'] = true;
} catch (Throwable $error) {
    $result['ok'] = false;
    $result['error'] = $error->getMessage();
}
echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
exit($result['ok'] ? 0 : 1);
