<?php

namespace Cesurapp\SwooleBundle\Tests\Client;

use Cesurapp\SwooleBundle\Client\SwooleBridge;
use Cesurapp\SwooleBundle\Client\SwooleClient;
use Cesurapp\SwooleBundle\Tests\Kernel;
use OpenSwoole\Coroutine\Scheduler;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

class ClientBridgeTest extends KernelTestCase
{
    protected function setUp(): void
    {
        $_SERVER['KERNEL_CLASS'] = Kernel::class;
    }

    public function testBrideClientDecorate(): void
    {
        $client = self::getContainer()->get('http_client');
        $this->assertInstanceOf(SwooleBridge::class, $client);
    }

    public function testClient(): void
    {
        /** @var SwooleBridge $client */
        $client = self::getContainer()->get('http_client');

        $scheduler = new Scheduler();
        $scheduler->add(function () use ($client) {
            $req = $client->request('GET', 'https://www.google.com');
            $this->assertSame(200, $req->getStatusCode());

            // Test Query String Parameters
            $req = $client->request('GET', 'https://www.google.com', [
                'query' => ['test' => 'value'],
            ]);
            $this->assertSame(200, $req->getStatusCode());
            $this->assertStringContainsString('test=value', urldecode($req->getContent()));
        });
        $scheduler->start();
    }

    public function testClientStatic(): void
    {
        $scheduler = new Scheduler();
        $scheduler->add(function () {
            $req = SwooleClient::create('https://www.google.com')->get();
            $this->assertSame(200, $req->getStatusCode());
        });
        $scheduler->start();
    }
}
