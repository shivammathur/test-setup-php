<?php

namespace Cesurapp\SwooleBundle\Tests;

use Cesurapp\SwooleBundle\SwooleBundle;
use Doctrine\Bundle\DoctrineBundle\DoctrineBundle;
use Symfony\Bundle\FrameworkBundle\FrameworkBundle;
use Symfony\Bundle\FrameworkBundle\Kernel\MicroKernelTrait;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;
use Symfony\Component\HttpKernel\Kernel as BaseKernel;
use Symfony\Component\HttpKernel\Log\Logger;
use Symfony\Component\Routing\Loader\Configurator\RoutingConfigurator;

/**
 * Create App Test Kernel.
 */
class Kernel extends BaseKernel
{
    use MicroKernelTrait;

    public function registerBundles(): iterable
    {
        return [
            new FrameworkBundle(),
            new DoctrineBundle(),
            new SwooleBundle(),
        ];
    }

    protected function configureContainer(ContainerConfigurator $container): void
    {
        $container->extension('framework', [
            'test' => true,
            'http_client' => [],
        ]);

        // Swoole Bundle Default Configuration
        $container->extension('swoole', [
            'entrypoint' => 'tests/index.php',
            'replace_http_client' => true,
            'cron_worker' => true,
            'task_worker' => true,
        ]);

        // Doctrine Bundle Default Configuration
        $container->extension('doctrine', [
            'dbal' => [
                'default_connection' => 'default',
                'url' => 'sqlite:///%kernel.project_dir%/var/database.sqlite',
            ],
            'orm' => [
                'auto_generate_proxy_classes' => false,
                'enable_lazy_ghost_objects' => true,
                'report_fields_where_declared' => true,
                'naming_strategy' => 'doctrine.orm.naming_strategy.underscore_number_aware',
                'auto_mapping' => true,
                'controller_resolver' => [
                    'auto_mapping' => false,
                ],
            ],
        ]);

        $services = $container->services()->defaults()->autowire()->autoconfigure();
        $services->load('Cesurapp\\SwooleBundle\\Tests\\_App\\Cron\\', '_App/Cron');
        $services->load('Cesurapp\\SwooleBundle\\Tests\\_App\\Task\\', '_App/Task');

        $services->set('logger', Logger::class)
            ->public()
            ->args([
                '$formatter' => null,
                '$minLevel' => 'info',
                '$output' => '%kernel.logs_dir%/test.log',
            ]);
    }

    protected function configureRoutes(RoutingConfigurator $routes): void
    {
        $routes->import('_App/Controller', 'attribute');
    }
}
