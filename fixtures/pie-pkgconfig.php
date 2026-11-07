<?php
// Diagnose why PIE falls back from a batch to individual pkg-config probes.
$phar = sys_get_temp_dir() . '/pie-profile.phar';
copy($argv[1], $phar);
require 'phar://' . str_replace('\\', '/', $phar) . '/vendor/autoload.php';
$libraries = array_values((new ReflectionClass(Php\Pie\ComposerIntegration\PhpBinaryPathBasedPlatformRepository::class))->getConstant('PKG_CONFIG_LIBRARIES'));
$run = static function (array $args): array {
    $process = new Symfony\Component\Process\Process(['pkg-config', ...$args]);
    $process->run();
    return ['args' => $args, 'exit' => $process->getExitCode(), 'stdout' => $process->getOutput(), 'stderr' => $process->getErrorOutput()];
};
$list = $run(['--list-all']);
$available = array_map(static fn ($line) => explode(' ', trim($line), 2)[0], explode("\n", trim($list['stdout'])));
$available = array_values(array_intersect($libraries, $available));
$batch = $run(['--modversion', ...$available]);
$individual = array_map(static fn ($library) => $run(['--modversion', $library]), $available);
file_put_contents('artifacts/pie-pkgconfig.json', json_encode(compact('available', 'batch', 'individual'), JSON_PRETTY_PRINT));
