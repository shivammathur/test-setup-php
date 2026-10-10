<?php
declare(strict_types=1);

file_put_contents(__DIR__ . '/evidence/runtime-' . getmypid() . '.json', json_encode([
    'pid' => getmypid(),
    'argv' => $_SERVER['argv'],
    'php' => PHP_VERSION,
    'zts' => (bool) PHP_ZTS,
    'turbo_loaded' => extension_loaded('phpstan_turbo'),
    'turbo_version' => phpversion('phpstan_turbo'),
    'turbo_active' => PHPStan\Turbo\TurboExtensionEnabler::isActive(),
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
