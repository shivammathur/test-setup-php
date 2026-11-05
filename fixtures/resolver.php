<?php
require $argv[1] . '/src/scripts/extensions/release.php';
function checkRelease($value, $message) { if (!$value) { throw new RuntimeException($message); } }
$platform = array('php' => '8.5', 'version' => '8.5.12', 'bits' => 64, 'os' => 'linux', 'arch' => 'x86_64', 'zts' => false, 'debug' => false, 'libc' => 'glibc', 'compiler' => '');
function packageRelease($version, $extra = array()) { return array_merge(array('version' => $version, 'type' => 'php-ext', 'php-ext' => array('extension-name' => 'native'), 'require' => array('php' => '^8.2')), $extra); }
$old = packageRelease('1.9.0', array('php-ext' => array('extension-name' => 'native', 'download-url-method' => array('pre-packaged-binary'))));
$latest = packageRelease('2.0.0');
$packages = array($old, $latest, packageRelease('3.0.0-RC1'), packageRelease('3.0.0', array('require' => array('php' => '>=99'))));
checkRelease(ExtensionRelease::selectPackage($packages, 'latest', $platform)['version'] === '2.0.0', 'Latest compatible stable release not selected');
checkRelease(ExtensionRelease::selectPackage($packages, '1', $platform)['version'] === '1.9.0', 'Major version request not honored');
checkRelease(ExtensionRelease::selectPackage($packages, '^3.0@RC', $platform)['version'] === '3.0.0-RC1', 'Explicit prerelease not selected');
$conflict = packageRelease('4.0.0', array('conflict' => array('php' => '^8.5')));
checkRelease(ExtensionRelease::selectPackage(array($conflict, $latest), '*', $platform)['version'] === '2.0.0', 'PHP conflict ignored');
$metadata = array('minified' => 'composer/2.0', 'packages' => array('fixture/native' => array($latest, array('version' => '1.9.0', 'require' => '__unset'))));
$expanded = ExtensionRelease::expand($metadata, 'fixture/native');
checkRelease(!isset($expanded[1]['require']) && $expanded[1]['php-ext']['extension-name'] === 'native', 'Metadata inheritance or unset semantics broken');
$cases = array(array('1.2.3', '^1.2', true), array('2.0.0', '^1.2', false), array('0.3.9', '^0.3', true), array('0.4.0', '^0.3', false), array('1.2.9', '~1.2.3', true), array('1.3.0', '~1.2.3', false), array('8.5.12', '~8.2.0 || ~8.5.0', true), array('8.5.12', '>=8.1,<8.5', false), array('8.6.0-dev', '^8.6', true), array('1.2.0-RC1', '>=1.2 <2.0', true), array('2.1', '1.0 - 2.0', false), array('2.0.9', '1.0 - 2.0', true), array('1.2.0-RC1', '^1.2-stable', false), array('1.2.0-RC1', '~1.2-stable', false), array('1.2.0-RC1', '>=1.2-stable', false), array('1.2.0-RC1', '<1.2-stable', true));
foreach ($cases as $case) { checkRelease(ExtensionRelease::satisfies($case[0], $case[1]) === $case[2], 'Wrong range result: ' . json_encode($case)); }
function asset($name) { return array('name' => $name, 'browser_download_url' => 'https://example.invalid/' . $name); }
$assets = array(asset('php_native-2.0.0_php8.5-arm64-linux-glibc.zip'), asset('php_native-2.0.0_php8.5-x86_64-linux-musl.zip'), asset('php_native-2.0.0_php8.5-x86_64-linux-glibc-zts.zip'), asset('php_native-2.0.0_php8.5-x86_64-linux-glibc-debug.zip'), asset('php_native-2.0.0_php8.5-x86_64-linux-glibc.zip'), asset('php_native-2.0.0_php8.5-x86_64-linux-anylibc.zip'));
checkRelease(ExtensionRelease::selectAsset($assets, 'native', '2.0.0', $platform)['name'] === $assets[4]['name'], 'Wrong Linux ABI selected');
checkRelease(ExtensionRelease::selectAsset(array($assets[4]), 'native', '1.9.0', $platform) === null, 'Selected a binary for another release');
checkRelease(ExtensionRelease::selectAsset(array(asset('php_native-1.9.0_php8.5-x86_64-linux-glibc.zip')), 'native', '2.0.0', $platform) === null, 'Downgraded to find a binary');
checkRelease(ExtensionRelease::selectAsset(array($assets[5]), 'native', '2.0.0', $platform)['name'] === $assets[5]['name'], 'Explicit anylibc compatibility rejected');
$platform['os'] = 'windows'; $platform['compiler'] = 'vs17';
$windows = array(asset('php_native-2.0.0-8.5-nts-vs16-x86_64.zip'), asset('php_native-2.0.0-8.5-ts-vs17-x86_64.zip'), asset('php_native-2.0.0-8.5-vs17-nts-x86_64.zip'));
checkRelease(ExtensionRelease::selectAsset($windows, 'native', '2.0.0', $platform)['name'] === $windows[2]['name'], 'Wrong Windows compiler or thread safety selected');
$platform['zts'] = true;
checkRelease(ExtensionRelease::selectAsset($windows, 'native', '2.0.0', $platform)['name'] === $windows[1]['name'], 'ZTS binary not selected');
$platform['os'] = 'darwin'; $platform['arch'] = 'arm64'; $platform['libc'] = 'bsdlibc'; $platform['zts'] = false;
$mac = asset('php_native-2.0.0_php8.5-arm64-darwin-bsdlibc.so');
checkRelease(ExtensionRelease::selectAsset(array($mac), 'native', 'v2.0.0', $platform)['name'] === $mac['name'], 'Raw macOS module or v-prefixed version not supported');
$duplicate = $mac; $duplicate['name'] = strtoupper($mac['name']);
try { ExtensionRelease::selectAsset(array($mac, $duplicate), 'native', '2.0.0', $platform); throw new LogicException('Ambiguous binaries silently accepted'); }
catch (RuntimeException $expected) { checkRelease(strpos($expected->getMessage(), 'Multiple') !== false, 'Unexpected ambiguity error'); }
echo "Release selection, constraints, metadata decoding, source policy, ABI matching and ambiguous-asset rejection passed.\n";
