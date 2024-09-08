<?php

namespace Cesurapp\SwooleBundle\Runtime\SwooleServer;

use Cesurapp\SwooleBundle\Cron\CronWorker;
use Swoole\Process;
use Symfony\Component\HttpKernel\HttpKernelInterface;

class CronServer
{
    public function __construct(HttpKernelInterface $application, HttpServer $server, array $options)
    {
        if (!$options['worker']['cron']) {
            return;
        }

        $server->addProcess(new Process(function () use ($application) {
            $kernel = clone $application;
            $kernel->boot(); // @phpstan-ignore-line
            $worker = $kernel->getContainer()->get(CronWorker::class); // @phpstan-ignore-line

            while (true) { // @phpstan-ignore-line
                sleep(5);
                $worker->run();
                sleep(55);
            }
        }, false, 2, true));
    }
}
