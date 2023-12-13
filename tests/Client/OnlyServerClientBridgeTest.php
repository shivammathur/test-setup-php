<?php

namespace Cesurapp\SwooleBundle\Tests\Client;

use Cesurapp\SwooleBundle\Tests\KernelOnlyServer;

class OnlyServerClientBridgeTest extends ClientBridgeTest
{
    protected function setUp(): void
    {
        $_SERVER['KERNEL_CLASS'] = KernelOnlyServer::class;
    }
}
