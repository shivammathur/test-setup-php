<?php

namespace Cesurapp\SwooleBundle\Tests\Cron;

use Cesurapp\SwooleBundle\Tests\KernelOnlyServer;

class OnlyServerCronWorkerTest extends CronWorkerTest
{
    protected function setUp(): void
    {
        $_SERVER['KERNEL_CLASS'] = KernelOnlyServer::class;
    }
}
