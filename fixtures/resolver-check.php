<?php
Phar::loadPhar(realpath($argv[2]));
require 'phar://composer.phar/vendor/autoload.php';
require $argv[1] . '/src/scripts/extensions/pie.php';
function verify($condition, $message) {
    if (!$condition) { throw new RuntimeException($message); }
}
$name = 'fixture/native';
function release($version, $options = array(), $requires = array()) {
    return array('version' => $version, 'type' => 'php-ext', 'php-ext' => array_merge(array('extension-name' => 'native'), $options), 'require' => $requires);
}
$old = release('1.9.0', array('download-url-method' => array('pre-packaged-binary')));
$new = release('2.0.0');
$future = release('3.0.0', array(), array('php' => '>=99.0'));
$metadata = array('packages' => array($name => array($old, $new, $future, release('3.0.0-RC1'))));
$selected = PieRelease::selectPackage($metadata, $name, '*', 'native', 'linux');
verify($selected['version'] === '2.0.0', 'Latest compatible stable release not selected');
$platform = array('php' => '8.5', 'os' => 'linux', 'arch' => 'x86_64', 'zts' => false, 'debug' => false, 'libc' => 'glibc', 'compiler' => '');
verify(PieRelease::assetNames($selected, $platform) === array(), 'Source-only latest release incorrectly fell back to older binary release');
verify(PieRelease::selectPackage($metadata, $name, '^1.0', 'native', 'linux')['version'] === '1.9.0', 'Composer constraint not honored');
verify(PieRelease::selectPackage($metadata, $name, '^3.0@RC', 'native', 'linux')['version'] === '3.0.0-RC1', 'Explicit prerelease constraint not honored');
$minified = $metadata;
$minified['minified'] = 'composer/2.0';
$minified['packages'][$name] = Composer\MetadataMinifier\MetadataMinifier::minify(array($new, $old));
verify(PieRelease::selectPackage($minified, $name, '^1', 'native', 'linux')['version'] === '1.9.0', 'Minified Packagist metadata was not expanded');
$assets = array('assets' => array(
    array('name' => 'php_native-1.9.0_php8.5-x86_64-linux-musl.zip', 'url' => 'wrong-libc'),
    array('name' => 'php_native-1.9.0_php8.5-arm64-linux-glibc.zip', 'url' => 'wrong-arch'),
    array('name' => 'php_native-1.9.0_php8.5-x86_64-linux-glibc-zts.zip', 'url' => 'wrong-zts'),
    array('name' => 'php_native-1.9.0_php8.5-x86_64-linux-glibc.zip', 'url' => 'correct'),
));
verify(PieRelease::selectAsset($assets, PieRelease::assetNames($old, $platform))['url'] === 'correct', 'Wrong native ABI selected');
$platform['os'] = 'windows';
$platform['compiler'] = 'vs17';
$assets = array('assets' => array(
    array('name' => 'php_native-2.0.0-8.5-nts-vs16-x86_64.zip', 'url' => 'wrong-compiler'),
    array('name' => 'php_native-2.0.0-8.5-ts-vs17-x86_64.zip', 'url' => 'wrong-zts'),
    array('name' => 'php_native-2.0.0-8.5-nts-vs17-x86_64.zip', 'url' => 'correct'),
));
verify(PieRelease::selectAsset($assets, PieRelease::assetNames($new, $platform))['url'] === 'correct', 'Wrong Windows ABI selected');
$platform['os'] = 'darwin';
$platform['arch'] = 'arm64';
$platform['libc'] = 'bsdlibc';
$assets = array('assets' => array(array('name' => 'php_native-1.9.0_php8.5-arm64-darwin-bsdlibc.zip', 'url' => 'correct')));
verify(PieRelease::selectAsset($assets, PieRelease::assetNames($old, $platform))['url'] === 'correct', 'macOS asset was not matched');
echo "Version constraints, stable/prerelease selection, minified metadata, source-only latest, and native ABI selection passed.\n";
