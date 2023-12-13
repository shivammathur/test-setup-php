<?php

namespace Cesurapp\SwooleBundle\Runtime\SwooleServer;

use Cesurapp\SwooleBundle\Cron\CronWorker;
use OpenSwoole\Timer;
use Symfony\Component\HttpKernel\HttpKernelInterface;

class CronServer
{
    public function __construct(HttpKernelInterface $application, HttpServer $server, array $options)
    {
        if (!$options['worker']['cron']) {
            return;
        }

        $kernel = clone $application;
        $kernel->boot(); // @phpstan-ignore-line
        $worker = $kernel->getContainer()->get(CronWorker::class); // @phpstan-ignore-line

        // Work
        $server->on('start', function () use ($worker) {
            Timer::tick(1000 * 60, static fn () => $worker->run());
        });
    }
}
