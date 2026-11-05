<?php
declare(strict_types=1);

function recordTurbo(string $kind): void
{
    $expected = PHPStan\Turbo\TurboExtensionEnabler::getExpectedVersion();
    $active = PHPStan\Turbo\TurboExtensionEnabler::isActive();
    $loaded = extension_loaded('phpstan_turbo');
    if (($kind === 'rule' || getenv('PHPSTAN_INSTALL_METHOD') !== 'composer') && (!$loaded || !$active || phpversion('phpstan_turbo') !== $expected)) {
        throw new RuntimeException('Turbo is not loaded and active: ' . json_encode(['loaded' => $loaded, 'active' => $active, 'expected' => $expected, 'version' => phpversion('phpstan_turbo')]));
    }
    file_put_contents(
        __DIR__ . '/../artifacts/processes.jsonl',
        json_encode([
            'kind' => $kind,
            'mode' => getenv('PHPSTAN_RUN_MODE'),
            'pid' => getmypid(),
            'loaded' => $loaded,
            'active' => $active,
            'version' => phpversion('phpstan_turbo'),
        ], JSON_THROW_ON_ERROR) . PHP_EOL,
        FILE_APPEND | LOCK_EX,
    );
}

final class TurboLoadedRule implements PHPStan\Rules\Rule
{
    private bool $recorded = false;

    public function getNodeType(): string
    {
        return PhpParser\Node\Stmt\Class_::class;
    }

    public function processNode(PhpParser\Node $node, PHPStan\Analyser\Scope $scope): array
    {
        if (!$this->recorded) {
            recordTurbo('rule');
            $this->recorded = true;
        }
        return [];
    }
}
