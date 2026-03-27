<?php

declare(strict_types=1);

$label = $argv[1] ?? 'unknown';
$reportPath = $argv[2] ?? null;

$report = array(
    'label' => $label,
    'php_version' => PHP_VERSION,
    'php_sapi' => PHP_SAPI,
    'arch_bits' => PHP_INT_SIZE * 8,
    'status' => 'running',
    'assertions' => 0,
    'checks' => array(),
);

function write_report(): void
{
    global $report, $reportPath;

    if ($reportPath === null || $reportPath === '') {
        return;
    }

    file_put_contents($reportPath, json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL);
}

function record_check(string $name, array $details = array()): void
{
    global $report;

    $report['checks'][] = array(
        'name' => $name,
        'details' => $details,
    );
}

function increment_assertions(): void
{
    global $report;

    $report['assertions']++;
}

function fail(string $message): never
{
    global $report;

    $report['status'] = 'failed';
    $report['failure'] = $message;
    write_report();
    fwrite(STDERR, $message . PHP_EOL);
    exit(1);
}

function assert_true(bool $condition, string $message): void
{
    increment_assertions();
    if (!$condition) {
        fail($message);
    }
}

function assert_same(mixed $expected, mixed $actual, string $message): void
{
    increment_assertions();
    if ($expected !== $actual) {
        fail($message . ' Expected ' . var_export($expected, true) . ', got ' . var_export($actual, true) . '.');
    }
}

function assert_not_false(mixed $value, string $message): mixed
{
    increment_assertions();
    if ($value === false) {
        fail($message);
    }

    return $value;
}

function image_rgba_at($image, int $x, int $y): array
{
    $index = imagecolorat($image, $x, $y);
    return imagecolorsforindex($image, $index);
}

function assert_color_close(array $actual, array $expected, int $tolerance, string $message): void
{
    foreach (array('red', 'green', 'blue') as $channel) {
        increment_assertions();
        if (abs($actual[$channel] - $expected[$channel]) > $tolerance) {
            fail(
                $message . ' Channel ' . $channel . ' differs too much: expected ' .
                $expected[$channel] . ', got ' . $actual[$channel] . '.'
            );
        }
    }
}

function clone_image($image, int $width, int $height)
{
    $copy = assert_not_false(imagecreatetruecolor($width, $height), 'Failed to create an image clone.');
    assert_true(imagealphablending($copy, false), 'Failed to disable alpha blending on the clone.');
    assert_true(imagesavealpha($copy, true), 'Failed to preserve alpha on the clone.');
    assert_true(imagecopy($copy, $image, 0, 0, 0, 0, $width, $height), 'Failed to clone the GD image.');
    return $copy;
}

function count_changed_pixels($before, $after, int $width, int $height): int
{
    $count = 0;
    for ($y = 0; $y < $height; $y++) {
        for ($x = 0; $x < $width; $x++) {
            if (imagecolorat($before, $x, $y) !== imagecolorat($after, $x, $y)) {
                $count++;
            }
        }
    }

    return $count;
}

function assert_image_roundtrip(
    string $path,
    int $expectedType,
    string $decoder,
    int $width,
    int $height,
    array $samples = array(),
    int $tolerance = 0
): void {
    assert_true(file_exists($path), "Image file was not created: $path");
    assert_true(filesize($path) > 0, "Image file is empty: $path");
    assert_same($expectedType, exif_imagetype($path), "Unexpected image type for $path.");

    $size = assert_not_false(getimagesize($path), "Unable to read image metadata for $path.");
    assert_same($width, $size[0], "Unexpected image width for $path.");
    assert_same($height, $size[1], "Unexpected image height for $path.");

    $image = assert_not_false($decoder($path), "Failed to decode image with $decoder.");
    assert_same($width, imagesx($image), "Decoded image width mismatch for $path.");
    assert_same($height, imagesy($image), "Decoded image height mismatch for $path.");

    foreach ($samples as $sample) {
        $actual = image_rgba_at($image, $sample['x'], $sample['y']);
        assert_color_close($actual, $sample['rgba'], $tolerance, "Unexpected pixel values for $path.");
    }

    imagedestroy($image);
}

function create_roundtrip_fixture(): array
{
    $width = 80;
    $height = 80;
    $image = assert_not_false(imagecreatetruecolor($width, $height), 'Failed to create the roundtrip fixture.');
    assert_true(imagealphablending($image, false), 'Failed to disable alpha blending on the roundtrip fixture.');
    assert_true(imagesavealpha($image, true), 'Failed to preserve alpha on the roundtrip fixture.');

    $transparent = assert_not_false(imagecolorallocatealpha($image, 0, 0, 0, 127), 'Failed to allocate the transparent swatch.');
    $navy = assert_not_false(imagecolorallocate($image, 18, 42, 88), 'Failed to allocate the navy swatch.');
    $green = assert_not_false(imagecolorallocate($image, 30, 190, 120), 'Failed to allocate the green swatch.');
    $orange = assert_not_false(imagecolorallocate($image, 210, 120, 50), 'Failed to allocate the orange swatch.');

    assert_true(imagefilledrectangle($image, 0, 0, $width - 1, $height - 1, $transparent), 'Failed to clear the roundtrip fixture.');
    assert_true(imagefilledrectangle($image, 40, 0, $width - 1, 39, $navy), 'Failed to draw the navy swatch.');
    assert_true(imagefilledrectangle($image, 0, 40, 39, $height - 1, $green), 'Failed to draw the green swatch.');
    assert_true(imagefilledrectangle($image, 40, 40, $width - 1, $height - 1, $orange), 'Failed to draw the orange swatch.');

    return array(
        'image' => $image,
        'width' => $width,
        'height' => $height,
        'samples' => array(
            'transparent' => array(
                'x' => 10,
                'y' => 10,
                'rgba' => array('red' => 0, 'green' => 0, 'blue' => 0),
            ),
            'navy' => array(
                'x' => 60,
                'y' => 20,
                'rgba' => array('red' => 18, 'green' => 42, 'blue' => 88),
            ),
            'green' => array(
                'x' => 20,
                'y' => 60,
                'rgba' => array('red' => 30, 'green' => 190, 'blue' => 120),
            ),
            'orange' => array(
                'x' => 60,
                'y' => 60,
                'rgba' => array('red' => 210, 'green' => 120, 'blue' => 50),
            ),
        ),
    );
}

function flatten_image($image, int $width, int $height)
{
    $flattened = assert_not_false(imagecreatetruecolor($width, $height), 'Failed to create the flattened image.');
    $white = assert_not_false(imagecolorallocate($flattened, 255, 255, 255), 'Failed to allocate the flatten background.');
    assert_true(imagefilledrectangle($flattened, 0, 0, $width - 1, $height - 1, $white), 'Failed to fill the flatten background.');
    assert_true(imagecopy($flattened, $image, 0, 0, 0, 0, $width, $height), 'Failed to flatten the image.');
    return $flattened;
}

assert_true(PHP_SAPI === 'cli', 'The custom suite must run on the CLI SAPI.');
assert_true(PHP_OS_FAMILY === 'Windows', 'The custom suite expects a Windows PHP build.');

$requiredExtensions = array(
    'curl',
    'exif',
    'gd',
    'intl',
    'mbstring',
    'openssl',
    'PDO',
    'pdo_sqlite',
    'sqlite3',
    'SimpleXML',
    'xml',
    'xmlreader',
    'xmlwriter',
    'zlib',
);

foreach ($requiredExtensions as $extension) {
    assert_true(extension_loaded($extension), "Missing required extension: $extension");
}

$curlVersion = curl_version();
assert_true(isset($curlVersion['version']) && $curlVersion['version'] !== '', 'curl_version() did not return a version.');
assert_true(defined('INTL_ICU_VERSION'), 'INTL_ICU_VERSION is not available.');
assert_true(defined('OPENSSL_VERSION_TEXT'), 'OPENSSL_VERSION_TEXT is not available.');

$json = json_encode(array('label' => $label, 'version' => PHP_VERSION), JSON_THROW_ON_ERROR);
$decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
assert_same($label, $decoded['label'], 'JSON roundtrip failed.');

$hash = hash('sha256', 'windows-gd-custom-suite');
assert_true($hash !== false && strlen($hash) === 64, 'hash() did not return a SHA256 digest.');

$compressed = gzencode('gd-suite-payload');
assert_true($compressed !== false, 'gzencode() failed.');
assert_same('gd-suite-payload', gzdecode($compressed), 'gzdecode() failed.');

$digest = openssl_digest('gd-suite-payload', 'sha256');
assert_true($digest !== false && strlen($digest) === 64, 'openssl_digest() failed.');

assert_same(6, mb_strlen('Grüße!', 'UTF-8'), 'mb_strlen() returned the wrong length.');
assert_same('STRASSE', mb_strtoupper('straße', 'UTF-8'), 'mb_strtoupper() returned the wrong value.');

$normalized = Normalizer::normalize("Cafe\u{0301}", Normalizer::FORM_C);
assert_same('Café', $normalized, 'Normalizer::normalize() returned the wrong value.');

$formatter = new NumberFormatter('en_US', NumberFormatter::DECIMAL);
$formatted = $formatter->format(12345.5);
assert_true(is_string($formatted) && str_contains($formatted, '12') && str_contains($formatted, '345'), 'NumberFormatter::format() failed.');

$db = new PDO('sqlite::memory:');
$db->exec('CREATE TABLE checks (id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
$insert = $db->prepare('INSERT INTO checks (name) VALUES (?)');
assert_true($insert !== false, 'Failed to prepare the SQLite statement.');
assert_true($insert->execute(array('gd-custom-suite')), 'Failed to insert a SQLite row.');
$value = $db->query('SELECT name FROM checks')->fetchColumn();
assert_same('gd-custom-suite', $value, 'Unexpected SQLite query result.');

$xml = new SimpleXMLElement('<root><child status="ok">gd-custom-suite</child></root>');
assert_same('ok', (string) $xml->child['status'], 'SimpleXML attribute read failed.');
assert_same('gd-custom-suite', (string) $xml->child, 'SimpleXML text read failed.');

$writer = new XMLWriter();
assert_true($writer->openMemory(), 'XMLWriter::openMemory() failed.');
$writer->startDocument('1.0', 'UTF-8');
$writer->startElement('root');
$writer->writeAttribute('status', 'ok');
$writer->text('gd-custom-suite');
$writer->endElement();
$writer->endDocument();
$xmlOutput = $writer->outputMemory();
assert_true(str_contains($xmlOutput, 'gd-custom-suite'), 'XMLWriter output did not contain the expected text.');

record_check('core-runtime', array(
    'curl_version' => $curlVersion['version'],
    'icu_version' => INTL_ICU_VERSION,
    'openssl_version' => OPENSSL_VERSION_TEXT,
));

$gdInfo = gd_info();
$requiredGdFlags = array(
    'FreeType Support',
    'GIF Read Support',
    'GIF Create Support',
    'JPEG Support',
    'PNG Support',
    'WebP Support',
    'BMP Support',
    'XPM Support',
    'AVIF Support',
);

foreach ($requiredGdFlags as $flag) {
    assert_true(!empty($gdInfo[$flag]), "gd_info() flag is missing or disabled: $flag");
}

record_check('gd-capabilities', array(
    'gd_version' => $gdInfo['GD Version'] ?? null,
    'freetype' => $gdInfo['FreeType Support'] ?? null,
    'jpeg' => $gdInfo['JPEG Support'] ?? null,
    'png' => $gdInfo['PNG Support'] ?? null,
    'webp' => $gdInfo['WebP Support'] ?? null,
    'avif' => $gdInfo['AVIF Support'] ?? null,
    'xpm' => $gdInfo['XPM Support'] ?? null,
));

$fonts = array(
    'C:\\Windows\\Fonts\\arial.ttf',
    'C:\\Windows\\Fonts\\segoeui.ttf',
    'C:\\Windows\\Fonts\\consola.ttf',
    'C:\\Windows\\Fonts\\tahoma.ttf',
);

$fontPath = null;
foreach ($fonts as $candidate) {
    if (file_exists($candidate)) {
        $fontPath = $candidate;
        break;
    }
}

assert_true($fontPath !== null, 'Unable to find a TrueType font for the FreeType GD checks.');
record_check('freetype-font', array('font' => $fontPath));

$width = 128;
$height = 96;
$image = assert_not_false(imagecreatetruecolor($width, $height), 'imagecreatetruecolor() failed.');
assert_true(imagealphablending($image, false), 'imagealphablending() failed.');
assert_true(imagesavealpha($image, true), 'imagesavealpha() failed.');

$transparent = assert_not_false(imagecolorallocatealpha($image, 0, 0, 0, 127), 'Failed to allocate the transparent background.');
$navy = assert_not_false(imagecolorallocate($image, 18, 42, 88), 'Failed to allocate the navy color.');
$green = assert_not_false(imagecolorallocate($image, 30, 190, 120), 'Failed to allocate the green color.');
$orange = assert_not_false(imagecolorallocate($image, 210, 120, 50), 'Failed to allocate the orange color.');
$white = assert_not_false(imagecolorallocate($image, 245, 245, 245), 'Failed to allocate the white color.');

assert_true(imagefilledrectangle($image, 0, 0, $width - 1, $height - 1, $transparent), 'Failed to fill the transparent background.');
assert_true(imagefilledrectangle($image, 8, 8, 119, 87, $navy), 'Failed to draw the base rectangle.');
assert_true(imagefilledellipse($image, 64, 48, 46, 28, $green), 'Failed to draw the accent ellipse.');
$polygon = array(88, 18, 114, 34, 100, 60, 80, 44);
assert_true(imagefilledpolygon($image, $polygon, $orange), 'Failed to draw the polygon.');
assert_true(imageline($image, 12, 78, 116, 78, $white), 'Failed to draw the base line.');
assert_true(imagefilter($image, IMG_FILTER_SMOOTH, 2), 'imagefilter() failed.');
$convolution = array(
    array(0.0, -1.0, 0.0),
    array(-1.0, 5.0, -1.0),
    array(0.0, -1.0, 0.0),
);
assert_true(imageconvolution($image, $convolution, 1.0, 0.0), 'imageconvolution() failed.');

$beforeTextImage = clone_image($image, $width, $height);
$bbox = assert_not_false(imagettfbbox(14.0, 0.0, $fontPath, 'GD Custom'), 'imagettfbbox() failed.');
$textResult = imagettftext($image, 14.0, 0.0, 16, 34, $white, $fontPath, 'GD Custom');
assert_true($textResult !== false, 'imagettftext() failed.');
$changedPixels = count_changed_pixels($beforeTextImage, $image, $width, $height);
assert_true($changedPixels > 60, 'imagettftext() did not visibly render text.');
imagedestroy($beforeTextImage);

$scaled = assert_not_false(imagescale($image, 64, 48, IMG_BILINEAR_FIXED), 'imagescale() failed.');
$cropped = assert_not_false(imagecrop($image, array('x' => 12, 'y' => 12, 'width' => 72, 'height' => 52)), 'imagecrop() failed.');
$rotated = assert_not_false(imagerotate($image, 15.0, $transparent), 'imagerotate() failed.');
assert_true(imageflip($scaled, IMG_FLIP_HORIZONTAL), 'imageflip() failed.');

record_check('gd-transformations', array(
    'bbox' => $bbox,
    'rendered_pixels' => $changedPixels,
    'scaled' => array(imagesx($scaled), imagesy($scaled)),
    'cropped' => array(imagesx($cropped), imagesy($cropped)),
    'rotated' => array(imagesx($rotated), imagesy($rotated)),
));

$baseDirectory = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'windows-gd-custom-' . bin2hex(random_bytes(6));
assert_true(mkdir($baseDirectory, 0777, true), 'Failed to create the temporary output directory.');

$pngPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.png';
$jpegHighPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test-high.jpg';
$jpegLowPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test-low.jpg';
$webpPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.webp';
$avifPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.avif';
$xpmPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.xpm';
$xpmPngPath = $baseDirectory . DIRECTORY_SEPARATOR . 'xpm.png';
$xpmJpegPath = $baseDirectory . DIRECTORY_SEPARATOR . 'xpm.jpg';

$roundtripFixture = create_roundtrip_fixture();
$roundtripImage = $roundtripFixture['image'];
$roundtripWidth = $roundtripFixture['width'];
$roundtripHeight = $roundtripFixture['height'];
$roundtripSamples = $roundtripFixture['samples'];

assert_true(imageinterlace($roundtripImage, true), 'imageinterlace() failed.');
assert_true(imageresolution($roundtripImage, 144, 144), 'imageresolution() failed.');
$configuredResolution = imageresolution($roundtripImage);
assert_true(is_array($configuredResolution), 'imageresolution() did not return the configured resolution.');
$configuredResolution = array_values($configuredResolution);
assert_same(144, (int) $configuredResolution[0], 'The configured horizontal resolution is incorrect.');
assert_same(144, (int) $configuredResolution[1], 'The configured vertical resolution is incorrect.');
assert_true(imagepng($roundtripImage, $pngPath, 6), 'imagepng() failed.');
assert_image_roundtrip(
    $pngPath,
    IMAGETYPE_PNG,
    'imagecreatefrompng',
    $roundtripWidth,
    $roundtripHeight,
    array(
        $roundtripSamples['navy'],
        $roundtripSamples['green'],
        $roundtripSamples['orange'],
    ),
    0
);

$pngString = assert_not_false(file_get_contents($pngPath), 'file_get_contents() failed for the PNG file.');
$pngFromString = assert_not_false(imagecreatefromstring($pngString), 'imagecreatefromstring() failed for the PNG payload.');
assert_same($roundtripWidth, imagesx($pngFromString), 'PNG created from string has the wrong width.');
assert_same($roundtripHeight, imagesy($pngFromString), 'PNG created from string has the wrong height.');
$transparentCorner = image_rgba_at($pngFromString, $roundtripSamples['transparent']['x'], $roundtripSamples['transparent']['y']);
assert_true($transparentCorner['alpha'] >= 120, 'PNG transparency was not preserved.');

record_check('png', array(
    'path' => basename($pngPath),
    'size' => filesize($pngPath),
    'transparent_alpha' => $transparentCorner['alpha'],
    'resolution' => $configuredResolution,
));

$flattened = flatten_image($roundtripImage, $roundtripWidth, $roundtripHeight);
assert_true(imagejpeg($flattened, $jpegHighPath, 92), 'imagejpeg() with high quality failed.');
assert_true(imagejpeg($flattened, $jpegLowPath, 45), 'imagejpeg() with low quality failed.');
assert_true(filesize($jpegHighPath) >= filesize($jpegLowPath), 'JPEG quality settings did not affect output size as expected.');
assert_image_roundtrip(
    $jpegHighPath,
    IMAGETYPE_JPEG,
    'imagecreatefromjpeg',
    $roundtripWidth,
    $roundtripHeight,
    array(
        $roundtripSamples['green'],
        $roundtripSamples['orange'],
    ),
    30
);

record_check('jpeg', array(
    'high_quality_size' => filesize($jpegHighPath),
    'low_quality_size' => filesize($jpegLowPath),
));

assert_true(function_exists('imagewebp'), 'imagewebp() is not available.');
assert_true(imagewebp($roundtripImage, $webpPath, 80), 'imagewebp() failed.');
assert_image_roundtrip(
    $webpPath,
    IMAGETYPE_WEBP,
    'imagecreatefromwebp',
    $roundtripWidth,
    $roundtripHeight,
    array(
        $roundtripSamples['navy'],
        $roundtripSamples['green'],
        $roundtripSamples['orange'],
    ),
    50
);
$webpImage = assert_not_false(imagecreatefromwebp($webpPath), 'imagecreatefromwebp() failed for the transparency check.');
$webpTransparent = image_rgba_at($webpImage, $roundtripSamples['transparent']['x'], $roundtripSamples['transparent']['y']);
assert_true($webpTransparent['alpha'] >= 100, 'WebP transparency was not preserved.');

record_check('webp', array(
    'path' => basename($webpPath),
    'size' => filesize($webpPath),
    'transparent_alpha' => $webpTransparent['alpha'],
));

assert_true(function_exists('imageavif'), 'imageavif() is not available.');
assert_true(imageavif($roundtripImage, $avifPath, 70, 6), 'imageavif() failed.');
assert_image_roundtrip(
    $avifPath,
    IMAGETYPE_AVIF,
    'imagecreatefromavif',
    $roundtripWidth,
    $roundtripHeight,
    array(
        $roundtripSamples['navy'],
        $roundtripSamples['green'],
        $roundtripSamples['orange'],
    ),
    60
);
$avifImage = assert_not_false(imagecreatefromavif($avifPath), 'imagecreatefromavif() failed for the transparency check.');
$avifTransparent = image_rgba_at($avifImage, $roundtripSamples['transparent']['x'], $roundtripSamples['transparent']['y']);
assert_true($avifTransparent['alpha'] >= 100, 'AVIF transparency was not preserved.');

record_check('avif', array(
    'path' => basename($avifPath),
    'size' => filesize($avifPath),
    'transparent_alpha' => $avifTransparent['alpha'],
));

$xpmData = <<<'XPM'
/* XPM */
static char * sample_xpm[] = {
"4 3 4 1",
"  c None",
". c #00FF00",
"+ c #0033FF",
"# c #FF8800",
".+ #",
"+#..",
" ## "
};
XPM;

assert_true(file_put_contents($xpmPath, $xpmData) !== false, 'Failed to write the XPM fixture.');
assert_true(function_exists('imagecreatefromxpm'), 'imagecreatefromxpm() is not available.');
$xpmImage = assert_not_false(imagecreatefromxpm($xpmPath), 'imagecreatefromxpm() failed.');
assert_same(4, imagesx($xpmImage), 'The decoded XPM width is incorrect.');
assert_same(3, imagesy($xpmImage), 'The decoded XPM height is incorrect.');
$xpmGreen = image_rgba_at($xpmImage, 0, 0);
assert_color_close($xpmGreen, array('red' => 0, 'green' => 255, 'blue' => 0), 0, 'Unexpected XPM green pixel.');

assert_true(imagepng($xpmImage, $xpmPngPath), 'Converting XPM to PNG failed.');
assert_true(imagejpeg($xpmImage, $xpmJpegPath, 90), 'Converting XPM to JPEG failed.');
assert_same(IMAGETYPE_PNG, exif_imagetype($xpmPngPath), 'Unexpected type for the converted XPM PNG.');
assert_same(IMAGETYPE_JPEG, exif_imagetype($xpmJpegPath), 'Unexpected type for the converted XPM JPEG.');

record_check('xpm', array(
    'path' => basename($xpmPath),
    'png_size' => filesize($xpmPngPath),
    'jpeg_size' => filesize($xpmJpegPath),
));

imagedestroy($xpmImage);
imagedestroy($pngFromString);
imagedestroy($webpImage);
imagedestroy($avifImage);
imagedestroy($flattened);
imagedestroy($roundtripImage);
imagedestroy($scaled);
imagedestroy($cropped);
imagedestroy($rotated);
imagedestroy($image);

$report['status'] = 'passed';
write_report();
echo 'Custom GD artifact suite passed for ' . $label . ' on PHP ' . PHP_VERSION . PHP_EOL;
