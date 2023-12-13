<?php

namespace Cesurapp\SwooleBundle\Tests\Runtime;

use Cesurapp\SwooleBundle\Tests\KernelOnlyServer;

class OnlyServerCommandTest extends ServerCommandTest
{
    protected function setUp(): void
    {
        $_SERVER['KERNEL_CLASS'] = KernelOnlyServer::class;
    }
}
