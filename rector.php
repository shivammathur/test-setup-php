<?php

declare(strict_types=1);

use Rector\Core\Configuration\Option;
use Rector\Core\Stubs\PHPStanStubLoader;
use Rector\Set\ValueObject\DowngradeSetList;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;

return static function (ContainerConfigurator $containerConfigurator): void {
    // get parameters
    $parameters = $containerConfigurator->parameters();

    $parameters->set(Option::PATHS, [
        __DIR__ . '/vendor/typisttech/imposter'
    ]);

    // Define what rule sets will be applied
    $parameters->set(Option::SETS, [
            DowngradeSetList::PHP_73,
            DowngradeSetList::PHP_72,
            DowngradeSetList::PHP_71,
            DowngradeSetList::PHP_70
    ]);

    $parameters->set(Option::PHP_VERSION_FEATURES, '7.0');

};