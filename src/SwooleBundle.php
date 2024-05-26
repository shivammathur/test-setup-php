<?php

namespace Cesurapp\SwooleBundle;

use Cesurapp\SwooleBundle\Client\SwooleBridge;
use Cesurapp\SwooleBundle\Cron\CronDataCollector;
use Cesurapp\SwooleBundle\Cron\CronInterface;
use Cesurapp\SwooleBundle\Cron\CronWorker;
use Cesurapp\SwooleBundle\Task\FailedTaskCron;
use Cesurapp\SwooleBundle\Task\TaskHandler;
use Cesurapp\SwooleBundle\Task\TaskInterface;
use Cesurapp\SwooleBundle\Task\TaskWorker;
use Symfony\Component\Config\Definition\Configurator\DefinitionConfigurator;
use Symfony\Component\DependencyInjection\Compiler\CompilerPassInterface;
use Symfony\Component\DependencyInjection\Compiler\ServiceLocatorTagPass;
use Symfony\Component\DependencyInjection\ContainerBuilder;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;
use Symfony\Component\DependencyInjection\Reference;
use Symfony\Component\HttpKernel\Bundle\AbstractBundle;

class SwooleBundle extends AbstractBundle
{
    public function configure(DefinitionConfigurator $definition): void
    {
        $definition->rootNode() // @phpstan-ignore-line
        ->children()
            ->scalarNode('entrypoint')->defaultValue('public/index.php')->end()
            ->scalarNode('watch_dir')->defaultValue('/config,/src,/templates')->end()
            ->scalarNode('watch_extension')->defaultValue('*.php,*.yaml,*.yml,*.twig')->end()
            ->booleanNode('replace_http_client')->defaultTrue()->end()
            ->booleanNode('cron_worker')->defaultTrue()->end()
            ->booleanNode('task_worker')->defaultFalse()->end()
            ->booleanNode('task_sync_mode')->defaultFalse()->end()
            ->scalarNode('failed_task_retry')->defaultValue('@EveryMinute10')->end()
            ->scalarNode('failed_task_attempt')->defaultValue(1)->end()
            ->end();
    }

    public function loadExtension(array $config, ContainerConfigurator $container, ContainerBuilder $builder): void
    {
        $services = $container->services()->defaults()->autowire()->autoconfigure();
        $services->load('Cesurapp\\SwooleBundle\\Command\\', './Command/Server*.*');
        foreach ($config as $key => $value) {
            $builder->setParameter('swoole.'.$key, $value);
        }

        // Register Swoole Http Client
        if ($builder->getParameter('swoole.replace_http_client')) {
            $def = $builder
                ->register(SwooleBridge::class, SwooleBridge::class)
                ->setDecoratedService('http_client', invalidBehavior: ContainerInterface::IGNORE_ON_INVALID_REFERENCE);
            if ('test' === $container->env()) {
                $def->setPublic(true);
            }
        }

        // Register Task Service
        if ($builder->getParameter('swoole.task_worker')) {
            $builder->registerForAutoconfiguration(TaskInterface::class)
                ->addTag('tasks')
                ->setLazy(true);

            $def = $builder->register(TaskHandler::class, TaskHandler::class);
            if ('test' === $container->env() || $builder->getParameter('swoole.task_sync_mode')) {
                $def->setArguments(['$worker' => new Reference(TaskWorker::class)]);
            }

            $services->load('Cesurapp\\SwooleBundle\\Command\\', './Command/Task*.*');
            $services->load('Cesurapp\\SwooleBundle\\Repository\\', './Repository');
            $services->load('Cesurapp\\SwooleBundle\\Entity\\', './Entity');

            // Failed Task Cron
            $builder->register(FailedTaskCron::class, FailedTaskCron::class);
        }

        // Register Cron Service
        if ($builder->getParameter('swoole.cron_worker')) {
            $builder->registerForAutoconfiguration(CronInterface::class)
                ->addTag('crons')
                ->setLazy(true);

            $builder->registerForAutoconfiguration(CronDataCollector::class)
                ->addTag('data_collector');

            $services->load('Cesurapp\\SwooleBundle\\Command\\', './Command/Cron*.*');
        }
    }

    public function build(ContainerBuilder $container): void
    {
        $container->addCompilerPass(new class () implements CompilerPassInterface {
            public function process(ContainerBuilder $container): void
            {
                // Init Task Worker
                if ($container->getParameter('swoole.task_worker')) {
                    $tasks = $container->findTaggedServiceIds('tasks');
                    array_walk($tasks, static fn (&$val, $id) => $val = new Reference($id));
                    $container
                        ->register(TaskWorker::class, TaskWorker::class)
                        ->addArgument(ServiceLocatorTagPass::register($container, $tasks))
                        ->setAutowired(true)
                        ->setPublic(true);
                }

                // Init Cron Worker
                if ($container->getParameter('swoole.cron_worker')) {
                    $crons = $container->findTaggedServiceIds('crons');
                    array_walk($crons, static fn (&$val, $id) => $val = new Reference($id));
                    $container
                        ->register(CronWorker::class, CronWorker::class)
                        ->addArgument(ServiceLocatorTagPass::register($container, $crons))
                        ->setAutowired(true)
                        ->setPublic(true);
                }
            }
        });

        parent::build($container);
    }
}
