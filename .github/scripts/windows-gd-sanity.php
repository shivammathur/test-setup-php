<?php

declare(strict_types=1);

function fail(string $message): void
{
    fwrite(STDERR, $message . PHP_EOL);
    exit(1);
}

function assert_true(bool $condition, string $message): void
{
    if (!$condition) {
        fail($message);
    }
}

function assert_same(mixed $expected, mixed $actual, string $message): void
{
    if ($expected !== $actual) {
        fail($message . ' Expected ' . var_export($expected, true) . ', got ' . var_export($actual, true) . '.');
    }
}

function assert_image_roundtrip(string $path, int $expectedType, string $decoder, int $width, int $height): void
{
    assert_true(file_exists($path), "Image file was not created: $path");
    assert_true(filesize($path) > 0, "Image file is empty: $path");

    $type = exif_imagetype($path);
    assert_same($expectedType, $type, "Unexpected image type for $path.");

    $size = getimagesize($path);
    assert_true($size !== false, "Unable to read image metadata for $path.");
    assert_same($width, $size[0], "Unexpected image width for $path.");
    assert_same($height, $size[1], "Unexpected image height for $path.");

    $image = $decoder($path);
    assert_true($image !== false, "Failed to decode image with $decoder.");
    assert_same($width, imagesx($image), "Decoded image width mismatch for $path.");
    assert_same($height, imagesy($image), "Decoded image height mismatch for $path.");
    imagedestroy($image);
}

$requiredExtensions = array(
    'curl',
    'gd',
    'intl',
    'mbstring',
    'openssl',
    'pdo_sqlite',
    'SimpleXML',
    'xml',
    'xmlreader',
    'xmlwriter',
    'zlib',
);

foreach ($requiredExtensions as $extension) {
    assert_true(extension_loaded($extension), "Missing required extension: $extension");
}

assert_true(PHP_SAPI === 'cli', 'The sanity script must run on the CLI SAPI.');
assert_true(str_contains(PHP_OS_FAMILY, 'Windows'), 'The sanity script expects a Windows PHP build.');

$json = json_encode(array('php' => PHP_VERSION, 'arch' => PHP_INT_SIZE, 'label' => 'windows-gd-e2e'), JSON_THROW_ON_ERROR);
$decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);
assert_same('windows-gd-e2e', $decoded['label'], 'JSON roundtrip failed.');

$hash = hash('sha256', 'windows-gd-e2e');
assert_true($hash !== false && strlen($hash) === 64, 'hash() did not return a SHA256 digest.');

$compressed = gzencode('gd-e2e-payload');
assert_true($compressed !== false, 'gzencode() failed.');
assert_same('gd-e2e-payload', gzdecode($compressed), 'gzdecode() failed.');

$digest = openssl_digest('gd-e2e-payload', 'sha256');
assert_true($digest !== false && strlen($digest) === 64, 'openssl_digest() failed.');

$db = new PDO('sqlite::memory:');
$db->exec('CREATE TABLE checks (id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
$statement = $db->prepare('INSERT INTO checks (name) VALUES (?)');
assert_true($statement !== false, 'Failed to prepare SQLite statement.');
assert_true($statement->execute(array('gd-e2e')), 'Failed to insert SQLite row.');
$value = $db->query('SELECT name FROM checks')->fetchColumn();
assert_same('gd-e2e', $value, 'Unexpected SQLite query result.');

$xml = new SimpleXMLElement('<root><child status="ok">gd-e2e</child></root>');
assert_same('ok', (string) $xml->child['status'], 'SimpleXML attribute read failed.');
assert_same('gd-e2e', (string) $xml->child, 'SimpleXML text read failed.');

$writer = new XMLWriter();
assert_true($writer->openMemory(), 'XMLWriter::openMemory() failed.');
$writer->startDocument('1.0', 'UTF-8');
$writer->startElement('root');
$writer->writeAttribute('status', 'ok');
$writer->text('gd-e2e');
$writer->endElement();
$writer->endDocument();
$xmlOutput = $writer->outputMemory();
assert_true(str_contains($xmlOutput, 'status="ok"'), 'XMLWriter output did not contain the expected attribute.');

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

$image = imagecreatetruecolor(96, 64);
assert_true($image !== false, 'imagecreatetruecolor() failed.');
assert_true(imagealphablending($image, false), 'imagealphablending() failed.');
assert_true(imagesavealpha($image, true), 'imagesavealpha() failed.');

$background = imagecolorallocatealpha($image, 20, 40, 80, 0);
$highlight = imagecolorallocate($image, 240, 240, 240);
$accent = imagecolorallocate($image, 20, 200, 140);

assert_true($background !== false, 'Failed to allocate the GD background color.');
assert_true($highlight !== false, 'Failed to allocate the GD highlight color.');
assert_true($accent !== false, 'Failed to allocate the GD accent color.');

assert_true(imagefilledrectangle($image, 0, 0, 95, 63, $background), 'imagefilledrectangle() failed.');
assert_true(imagefilledellipse($image, 48, 32, 40, 24, $accent), 'imagefilledellipse() failed.');
assert_true(imagefilter($image, IMG_FILTER_SMOOTH, 4), 'imagefilter() failed.');

$bbox = imagettfbbox(12.0, 0.0, $fontPath, 'GD E2E');
assert_true($bbox !== false, 'imagettfbbox() failed.');
$textResult = imagettftext($image, 12.0, 0.0, 8, 22, $highlight, $fontPath, 'GD E2E');
assert_true($textResult !== false, 'imagettftext() failed.');

$scaled = imagescale($image, 48, 32, IMG_BILINEAR_FIXED);
assert_true($scaled !== false, 'imagescale() failed.');
$copied = imagecreatetruecolor(96, 64);
assert_true($copied !== false, 'Failed to create the destination GD image.');
assert_true(imagecopyresampled($copied, $scaled, 0, 0, 0, 0, 96, 64, 48, 32), 'imagecopyresampled() failed.');

$baseDirectory = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'windows-gd-e2e-' . bin2hex(random_bytes(6));
assert_true(mkdir($baseDirectory, 0777, true), 'Failed to create the temporary output directory.');

$pngPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.png';
$jpegPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.jpg';
$webpPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.webp';
$avifPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.avif';
$xpmPath = $baseDirectory . DIRECTORY_SEPARATOR . 'test.xpm';

assert_true(imagepng($copied, $pngPath), 'imagepng() failed.');
assert_true(imagejpeg($copied, $jpegPath, 90), 'imagejpeg() failed.');
assert_true(function_exists('imagewebp'), 'imagewebp() is not available.');
assert_true(imagewebp($copied, $webpPath), 'imagewebp() failed.');
assert_true(function_exists('imageavif'), 'imageavif() is not available.');
assert_true(imageavif($copied, $avifPath), 'imageavif() failed.');

assert_image_roundtrip($pngPath, IMAGETYPE_PNG, 'imagecreatefrompng', 96, 64);
assert_image_roundtrip($jpegPath, IMAGETYPE_JPEG, 'imagecreatefromjpeg', 96, 64);
assert_image_roundtrip($webpPath, IMAGETYPE_WEBP, 'imagecreatefromwebp', 96, 64);
assert_image_roundtrip($avifPath, IMAGETYPE_AVIF, 'imagecreatefromavif', 96, 64);

$pngString = file_get_contents($pngPath);
assert_true($pngString !== false, 'file_get_contents() failed for the PNG file.');
$pngFromString = imagecreatefromstring($pngString);
assert_true($pngFromString !== false, 'imagecreatefromstring() failed for the PNG payload.');
assert_same(96, imagesx($pngFromString), 'PNG created from string has the wrong width.');
assert_same(64, imagesy($pngFromString), 'PNG created from string has the wrong height.');

$xpmData = <<<'XPM'
/* XPM */
static char * sample_xpm[] = {
"2 2 2 1",
"  c None",
". c #00FF00",
"..",
" ."
};
XPM;

assert_true(file_put_contents($xpmPath, $xpmData) !== false, 'Failed to write the XPM fixture.');
assert_true(function_exists('imagecreatefromxpm'), 'imagecreatefromxpm() is not available.');
$xpmImage = imagecreatefromxpm($xpmPath);
assert_true($xpmImage !== false, 'imagecreatefromxpm() failed.');
assert_same(2, imagesx($xpmImage), 'The decoded XPM width is incorrect.');
assert_same(2, imagesy($xpmImage), 'The decoded XPM height is incorrect.');

imagedestroy($xpmImage);
imagedestroy($pngFromString);
imagedestroy($scaled);
imagedestroy($copied);
imagedestroy($image);

echo 'GD artifact sanity checks passed for PHP ' . PHP_VERSION . PHP_EOL;
