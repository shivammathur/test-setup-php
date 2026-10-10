<?php
$tool = getenv('EXPECTED_TOOL');
$version = trim(file_get_contents('evidence/version.txt'));
$expected = match ($tool) {
    'phpstan:^0.12.68' => '0.12.68',
    'phpstan:0.12' => '0.12.',
    'phpstan:2.3.0' => '2.3.0',
};
if (!str_contains($version, $expected)) {
    throw new RuntimeException('Wrong fallback version: ' . $version);
}
if (!str_contains(file_get_contents('evidence/composer.txt'), 'Composer version 1.')) {
    throw new RuntimeException('The regression must run using Composer 1');
}
$binary = null;
foreach (explode(PATH_SEPARATOR, getenv('PATH')) as $directory) {
    if (is_file($directory . '/phpstan')) {
        $binary = str_replace('\\', '/', $directory . '/phpstan');
        break;
    }
}
if ($binary === null || str_contains($binary, '/_tools/')) {
    throw new RuntimeException('PHPStan did not fall back to the PHAR installation');
}
$archive = sys_get_temp_dir() . '/phpstan-fallback-' . getmypid() . '.phar';
copy($binary, $archive);
$phar = new Phar($archive);
$report = ['input' => $tool, 'version' => $version, 'binary' => $binary, 'sha256' => hash_file('sha256', $binary), 'phar_files' => count($phar), 'turbo_loaded' => extension_loaded('phpstan_turbo')];
file_put_contents('evidence/fallback.json', json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
echo json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
file_put_contents('fallback-fixture.php', '<?php function addOne(int $value): int { return $value + 1; }');
