<?php

namespace Cesurapp\SwooleBundle\Tests;

use Cesurapp\SwooleBundle\SwooleBundle;
use Symfony\Bundle\FrameworkBundle\FrameworkBundle;
use Symfony\Bundle\FrameworkBundle\Kernel\MicroKernelTrait;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;
use Symfony\Component\HttpKernel\Kernel as BaseKernel;
use Symfony\Component\HttpKernel\Log\Logger;
use Symfony\Component\Routing\Loader\Configurator\RoutingConfigurator;

/**
 * Create App Test Kernel.
 */
class KernelOnlyServer extends BaseKernel
{
    use MicroKernelTrait;

    public function registerBundles(): iterable
    {
        return [
            new FrameworkBundle(),
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
            'task_worker' => false,
        ]);

        $services = $container->services()->defaults()->autowire()->autoconfigure();
        $services->load('Cesurapp\\SwooleBundle\\Tests\\_App\\Cron\\', '_App/Cron');

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
