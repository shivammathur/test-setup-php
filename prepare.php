<?php
declare(strict_types=1);

function check(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

check(PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION === getenv('EXPECTED_PHP'), 'Wrong PHP version');
check((bool) PHP_ZTS === (getenv('EXPECTED_TS') === 'ts'), 'Wrong thread safety');

$bin = null;
foreach (explode(PATH_SEPARATOR, getenv('PATH')) as $directory) {
    if (is_file($directory . '/phpstan')) {
        $bin = str_replace('\\', '/', $directory);
        break;
    }
}
check($bin !== null && str_contains($bin, '/_tools/phpstan-'), 'PHPStan is not using its scoped Composer installation');
$scope = dirname($bin, 2);
$package = dirname($bin) . '/phpstan/phpstan';
$manifest = json_decode(file_get_contents($scope . '/composer.json'), true, flags: JSON_THROW_ON_ERROR);
check(isset($manifest['require']['phpstan/phpstan']), 'Scoped Composer requirement is missing');
check(is_file($package . '/phpstan.phar'), 'PHPStan PHAR missing from Composer package');
check(is_dir($package . '/turbo-ext'), 'Bundled Turbo extension directory is missing');

$platform = match (PHP_OS_FAMILY) {
    'Windows' => 'windows-x86_64',
    'Darwin' => php_uname('m') === 'arm64' ? 'macos-arm64' : 'macos-x86_64',
    'Linux' => 'linux-gnu-' . (in_array(php_uname('m'), ['aarch64', 'arm64'], true) ? 'arm64' : 'x86_64'),
};
$binary = sprintf('%s/turbo-ext/%s/phpstan_turbo-%d.%d%s.%s', $package, $platform, PHP_MAJOR_VERSION, PHP_MINOR_VERSION, PHP_ZTS ? '-zts' : '', PHP_OS_FAMILY === 'Windows' ? 'dll' : 'so');
$expected = getenv('EXPECT_TURBO') === '1';
check(is_file($binary) === $expected, 'Unexpected availability of Turbo binary: ' . $binary);
$report = [
    'php' => PHP_VERSION,
    'platform' => $platform,
    'zts' => (bool) PHP_ZTS,
    'package' => $package,
    'constraint' => $manifest['require']['phpstan/phpstan'],
    'turbo_expected' => $expected,
    'turbo_binary' => is_file($binary) ? $binary : null,
    'turbo_sha256' => is_file($binary) ? hash_file('sha256', $binary) : null,
    'turbo_version' => trim(file_get_contents($package . '/turbo-ext/.version')),
];
file_put_contents('evidence/package.json', json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
copy($scope . '/composer.lock', 'evidence/composer.lock');
echo json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
if ($expected) {
    passthru(escapeshellarg(PHP_BINARY) . ' -d ' . escapeshellarg('extension=' . $binary) . ' --ri phpstan_turbo', $exit);
    check($exit === 0, 'Bundled Turbo extension failed to load');
} else {
    echo "Upstream does not ship a Turbo binary for this runtime. Testing PHPStan fallback.\n";
}

mkdir('fixtures');
for ($i = 0; $i < 20; $i++) {
    file_put_contents("fixtures/example$i.php", "<?php\nfunction example$i(int \$value): int { return \$value + $i; }\n");
}
