<?php
declare(strict_types=1);

chdir(dirname(__DIR__));
@mkdir('artifacts');
@unlink('artifacts/processes.jsonl');

function check(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

function runPhpstan(string $name, array $arguments, int $expectedExit): string
{
    global $phar;
    putenv('PHPSTAN_RUN_MODE=' . $name);
    $stdout = 'artifacts/' . $name . '.stdout';
    $stderr = 'artifacts/' . $name . '.stderr';
    $process = proc_open(
        [PHP_BINARY, $phar, ...$arguments],
        [0 => ['pipe', 'r'], 1 => ['file', $stdout, 'w'], 2 => ['file', $stderr, 'w']],
        $pipes,
        getcwd(),
        null,
        ['bypass_shell' => true],
    );
    check(is_resource($process), 'Could not start PHPStan');
    fclose($pipes[0]);
    $exit = proc_close($process);
    $output = file_get_contents($stdout);
    echo $output, file_get_contents($stderr);
    check($exit === $expectedExit, "$name exited $exit, expected $expectedExit");
    return $output;
}

$launcher = realpath($argv[1]);
$method = $argv[2] ?? 'pie';
check(in_array($method, ['composer', 'pie'], true), 'Unknown install method: ' . json_encode($argv));
putenv('PHPSTAN_INSTALL_METHOD=' . $method);
check(is_string($launcher), 'PHPStan launcher not found');
$phar = $launcher;
if ($method === 'composer') {
    $phar = false;
    for ($directory = dirname($launcher); dirname($directory) !== $directory; $directory = dirname($directory)) {
        $candidate = $directory . '/phpstan/phpstan/phpstan.phar';
        if (is_file($directory . '/autoload.php') && is_file($candidate)) {
            $phar = realpath($candidate);
            break;
        }
    }
    check(is_string($phar), 'PHPStan was not installed through Composer (possible PHAR fallback)');
} else {
    check(extension_loaded('phpstan_turbo'), 'Turbo is not loaded in PHP');
}
$copy = sys_get_temp_dir() . '/phpstan-pie-validation.phar';
check(copy($phar, $copy), 'Could not inspect the installed PHPStan PHAR');
$archive = new Phar($copy);
check($archive->getSignature() !== false, 'PHPStan is not a signed PHAR');
$expectedTurboVersion = require 'phar://' . $copy . '/vendor/turbo-extension-version.php';
check(is_string($expectedTurboVersion), 'Could not read expected Turbo version');
if ($method !== 'composer') {
    check(phpversion('phpstan_turbo') === $expectedTurboVersion, 'Turbo and PHPStan versions do not match');
}
$report = [
    'method' => $method,
    'php' => PHP_VERSION,
    'os' => PHP_OS_FAMILY,
    'architecture' => php_uname('m'),
    'zts' => PHP_ZTS,
    'phpstanPhar' => $phar,
    'phpstanLauncher' => $launcher,
    'phpstanSha256' => hash_file('sha256', $phar),
    'pharSignature' => $archive->getSignature()['hash_type'],
    'turboVersion' => phpversion('phpstan_turbo'),
    'expectedTurboVersion' => $expectedTurboVersion,
];

@mkdir('fixture-good');
@mkdir('fixture-bad');
$template = <<<'PHP'
<?php
declare(strict_types=1);
namespace Fixture;
final class CLASS_NAME
{
    /** @param list<int> $values */
    public function __construct(private array $values) {}
    public function sum(): int
    {
        $sum = 0;
        foreach ($this->values as $value) { $sum += $value; }
        return $sum;
    }
    /** @return list<int> */
    public function doubled(): array
    {
        return array_map(static fn (int $value): int => $value * 2, $this->values);
    }
    public function firstPositive(): ?int
    {
        foreach ($this->values as $value) {
            if ($value > 0) { return $value; }
        }
        return null;
    }
}
PHP;
for ($index = 1; $index <= 24; $index++) {
    $class = 'Sample' . $index;
    file_put_contents("fixture-good/$class.php", str_replace('CLASS_NAME', $class, $template));
}
file_put_contents('fixture-bad/Broken.php', <<<'PHP'
<?php
declare(strict_types=1);
namespace Fixture;
final class Broken
{
    public function value(): int
    {
        return 'intentional type error';
    }
}
PHP);
file_put_contents('phpstan.neon', <<<'NEON'
parameters:
    level: max
    paths:
        - fixture-good
    tmpDir: artifacts/cache
    bootstrapFiles:
        - fixtures/bootstrap.php
    parallel:
        maximumNumberOfProcesses: 2
        minimumNumberOfJobsPerProcess: 1
        jobSize: 1
services:
    -
        class: TurboLoadedRule
        tags:
            - phpstan.rules.rule
NEON);
$common = ['--configuration=phpstan.neon', '--autoload-file=fixtures/guard.php', '--no-ansi'];
$version = runPhpstan('version', ['--version', '--no-ansi'], 0);
check(str_contains($version, 'PHPStan - PHP Static Analysis Tool 2.3.5'), 'Wrong PHPStan version');
$diagnose = runPhpstan('diagnose', ['diagnose', ...$common], 0);
if ($method !== 'composer') {
    check(str_contains($diagnose, 'Turbo extension: enabled (version ' . $expectedTurboVersion . ')'), 'PHPStan reports Turbo as inactive');
    check(str_contains($diagnose, 'loaded via php.ini, workers inherit it'), 'Turbo is not enabled through the PHP configuration');
}
runPhpstan('clear-cache', ['clear-result-cache', ...$common], 0);
$analysis = json_decode(runPhpstan('parallel', ['analyse', ...$common, '--no-progress', '--error-format=json'], 0), true, 512, JSON_THROW_ON_ERROR);
check($analysis['totals']['errors'] === 0 && $analysis['totals']['file_errors'] === 0, 'Clean analysis reported errors');
$invalid = json_decode(runPhpstan('invalid', ['analyse', ...$common, '--no-progress', '--error-format=json', 'fixture-bad'], 1), true, 512, JSON_THROW_ON_ERROR);
check($invalid['totals']['file_errors'] === 1, 'Expected exactly one deliberate type error');
$file = array_values($invalid['files'])[0];
check($file['messages'][0]['identifier'] === 'return.type', 'PHPStan did not report the expected return type error');
$records = array_map(static fn (string $line): array => json_decode($line, true, 512, JSON_THROW_ON_ERROR), file('artifacts/processes.jsonl', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES));
$parallel = array_values(array_filter($records, static fn (array $row): bool => $row['mode'] === 'parallel'));
$parents = array_values(array_filter($parallel, static fn (array $row): bool => $row['kind'] === 'bootstrap'));
check(count($parents) > 0, 'The analysis bootstrap did not run');
$parentPid = $parents[0]['pid'];
$workers = array_values(array_filter($parallel, static fn (array $row): bool => $row['kind'] === 'rule' && $row['pid'] !== $parentPid));
check(count($workers) > 0, 'Turbo was not verified in a separate analysis worker');
$report['workerPids'] = array_values(array_unique(array_column($workers, 'pid')));
$report['phpstanDiagnosisEnabled'] = str_contains($diagnose, 'Turbo extension: enabled (version ');
$report['cleanAnalysisPassed'] = true;
$report['deliberateTypeErrorDetected'] = true;
$report['workerTurboActive'] = true;
$report['analysisTurboVersion'] = $workers[0]['version'];
if ($method !== 'composer') {
    $extension = rtrim(ini_get('extension_dir'), '/\\') . '/' . (PHP_OS_FAMILY === 'Windows' ? 'php_phpstan_turbo.dll' : 'phpstan_turbo.so');
    check(copy($extension, 'artifacts/' . basename($extension)), 'Could not collect the installed Turbo binary');
    $report['extensionSha256'] = hash_file('sha256', $extension);
}
file_put_contents('artifacts/report.json', json_encode($report, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
echo json_encode($report, JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR), PHP_EOL;
