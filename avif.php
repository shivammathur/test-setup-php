<?php
declare(strict_types=1);

error_reporting(E_ALL);
set_error_handler(static function (int $severity, string $message, string $file, int $line): never {
    throw new ErrorException($message, 0, $severity, $file, $line);
});
is_dir('results') || mkdir('results');

function check(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

// Sample well inside the quadrants to allow normal AVIF chroma subsampling.
const SAMPLES = [
    [16, 16, [255, 0, 0]],
    [48, 16, [0, 255, 0]],
    [16, 48, [0, 0, 255]],
    [48, 48, [255, 255, 255]],
];

function checkPixels(callable $readPixel): array
{
    $pixels = [];
    foreach (SAMPLES as [$x, $y, $expected]) {
        $actual = $readPixel($x, $y);
        foreach ($expected as $channel => $value) {
            check(abs($actual[$channel] - $value) <= 30, "Pixel mismatch at $x,$y: " . json_encode($actual));
        }
        $pixels[] = $actual;
    }
    return $pixels;
}

function decodeGd(string $path): array
{
    $image = imagecreatefromavif($path);
    check($image instanceof GdImage, 'GD failed to decode AVIF');
    check(imagesx($image) === 64 && imagesy($image) === 64, 'GD decoded incorrect dimensions');
    $pixels = checkPixels(static function (int $x, int $y) use ($image): array {
        $color = imagecolorsforindex($image, imagecolorat($image, $x, $y));
        return [$color['red'], $color['green'], $color['blue']];
    });
    return ['dimensions' => [64, 64], 'pixels' => $pixels];
}

function decodeImagick(string $path): array
{
    $image = new Imagick($path);
    check($image->getImageWidth() === 64 && $image->getImageHeight() === 64, 'Imagick decoded incorrect dimensions');
    $image->transformImageColorspace(Imagick::COLORSPACE_SRGB);
    $pixels = checkPixels(static function (int $x, int $y) use ($image): array {
        $color = $image->getImagePixelColor($x, $y)->getColor();
        return [$color['r'], $color['g'], $color['b']];
    });
    return ['format' => $image->getImageFormat(), 'dimensions' => [64, 64], 'pixels' => $pixels];
}

$result = [
    'php' => PHP_VERSION,
    'php_debug' => PHP_DEBUG,
    'php_zts' => PHP_ZTS,
    'architecture' => php_uname('m'),
    'runner_environment' => getenv('RUNNER_ENVIRONMENT'),
    'expected' => [getenv('EXPECTED_OS'), getenv('EXPECTED_BUILD'), getenv('EXPECTED_TS')],
    'gd' => extension_loaded('gd') ? gd_info() : null,
    'imagick' => extension_loaded('imagick') ? [
        'extension' => phpversion('imagick'),
        'library' => Imagick::getVersion(),
        'avif_formats' => Imagick::queryFormats('AVIF'),
    ] : null,
    'checks' => [],
];

$run = static function (string $name, callable $test) use (&$result): void {
    try {
        $result['checks'][$name] = ['ok' => true, 'details' => $test()];
    } catch (Throwable $error) {
        $result['checks'][$name] = ['ok' => false, 'error' => $error->getMessage()];
    }
};

$run('runtime', static function (): array {
    check(PHP_MAJOR_VERSION === 8 && PHP_MINOR_VERSION === 6, 'Expected PHP 8.6');
    check((bool) PHP_ZTS === (getenv('EXPECTED_TS') === 'zts'), 'PHP_ZTS differs from requested build');
    $os = parse_ini_file('/etc/os-release');
    preg_match('/ubuntu-(\d+\.\d+)/', getenv('EXPECTED_OS'), $match);
    check($os['ID'] === 'ubuntu' && $os['VERSION_ID'] === $match[1], 'Unexpected Ubuntu version');
    $arm = str_ends_with(getenv('EXPECTED_OS'), '-arm');
    check(php_uname('m') === ($arm ? 'aarch64' : 'x86_64'), 'Unexpected architecture');
    check(getenv('RUNNER_ENVIRONMENT') === 'github-hosted', 'Expected GitHub-hosted runner');
    // setup-php debug=true installs split debug symbols, not --enable-debug PHP.
    exec('readelf --notes ' . escapeshellarg(PHP_BINARY) . ' 2>/dev/null', $notes, $status);
    check($status === 0 && preg_match('/Build ID: ([a-f0-9]+)/', implode("\n", $notes), $id) === 1, 'PHP ELF build ID is missing');
    $symbols = '/usr/lib/debug/.build-id/' . substr($id[1], 0, 2) . '/' . substr($id[1], 2) . '.debug';
    $hasSymbols = is_file($symbols) && filesize($symbols) > 0;
    check($hasSymbols === (getenv('EXPECTED_BUILD') === 'debug'), 'PHP debug symbols differ from requested build');
    if ($hasSymbols) {
        exec('readelf --section-headers --wide ' . escapeshellarg($symbols) . ' 2>/dev/null', $sections, $status);
        check($status === 0 && str_contains(implode("\n", $sections), '.debug_info'), 'PHP symbol file has no debug info');
        exec('readelf --notes ' . escapeshellarg($symbols) . ' 2>/dev/null', $symbolNotes, $status);
        check($status === 0 && str_contains(implode("\n", $symbolNotes), 'Build ID: ' . $id[1]), 'PHP symbol file build ID does not match');
    }
    return ['ubuntu' => $os['VERSION_ID'], 'php_build_id' => $id[1], 'debug_symbols' => $hasSymbols, 'debug_symbols_path' => $symbols];
});

foreach (['gd', 'imagick'] as $encoder) {
    $run("$encoder-encode", static function () use ($encoder): array {
        check(extension_loaded($encoder), "$encoder extension is missing");
        $path = "results/$encoder.avif";
        if ($encoder === 'gd') {
            check((gd_info()['AVIF Support'] ?? false) && function_exists('imageavif'), 'GD AVIF support is missing');
            $image = imagecreatetruecolor(64, 64);
            foreach (SAMPLES as [$x, $y, $rgb]) {
                $left = $x < 32 ? 0 : 32;
                $top = $y < 32 ? 0 : 32;
                $color = imagecolorallocate($image, ...$rgb);
                check(imagefilledrectangle($image, $left, $top, $left + 31, $top + 31, $color), 'GD drawing failed');
            }
            check(imagepng($image, 'results/gd-source.png'), 'GD PNG control failed');
            check(imageavif($image, $path, 90, 6), 'GD AVIF encoding failed');
        } else {
            check(Imagick::queryFormats('AVIF') !== [], 'Imagick AVIF support is missing');
            $image = new Imagick();
            $image->newImage(64, 64, 'white', 'PNG');
            $image->setImageColorspace(Imagick::COLORSPACE_SRGB);
            foreach (SAMPLES as [$x, $y, $rgb]) {
                $left = $x < 32 ? 0 : 32;
                $top = $y < 32 ? 0 : 32;
                $draw = new ImagickDraw();
                $draw->setFillColor(sprintf('rgb(%d,%d,%d)', ...$rgb));
                $draw->rectangle($left, $top, $left + 31, $top + 31);
                check($image->drawImage($draw), 'Imagick drawing failed');
            }
            check($image->writeImage('results/imagick-source.png'), 'Imagick PNG control failed');
            $image->setImageFormat('AVIF');
            $image->setImageCompressionQuality(90);
            $blob = $image->getImageBlob();
            check(strlen($blob) > 0, 'Imagick returned an empty AVIF');
            check(file_put_contents($path, $blob) === strlen($blob), 'Could not save Imagick AVIF');
        }
        clearstatcache(true, $path);
        check(is_file($path) && filesize($path) > 0, "$encoder produced an empty AVIF");
        $blob = file_get_contents($path);
        check(substr($blob, 4, 4) === 'ftyp' && preg_match('/avif|avis/', substr($blob, 8, 40)) === 1, 'Invalid AVIF container');
        return ['bytes' => strlen($blob), 'sha256' => hash('sha256', $blob)];
    });
    // Check each decoder independently, including cross-library compatibility.
    foreach (['gd', 'imagick'] as $decoder) {
        $run("$encoder-to-$decoder", static function () use ($encoder, $decoder): array {
            $path = "results/$encoder.avif";
            check(is_file($path) && filesize($path) > 0, 'Encoder did not produce an AVIF');
            return $decoder === 'gd' ? decodeGd($path) : decodeImagick($path);
        });
    }
}

$result['ok'] = !in_array(false, array_column($result['checks'], 'ok'), true);
$json = json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
file_put_contents('results/result.json', $json);
echo $json;
exit($result['ok'] ? 0 : 1);
