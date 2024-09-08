<?php

namespace Cesurapp\SwooleBundle\Tests\Runtime;

use Cesurapp\SwooleBundle\Tests\Kernel;
use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Console\Tester\CommandTester;

class ServerCommandTest extends KernelTestCase
{
    protected function setUp(): void
    {
        $_SERVER['KERNEL_CLASS'] = Kernel::class;
    }

    public function test1StopFail(): void
    {
        sleep(1);
        self::bootKernel();
        $application = new Application(self::$kernel);

        $cmd = $application->find('server:stop');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute([]);
        $this->assertStringContainsString('Swoole HTTP server not found!', $cmdTester->getDisplay());
    }

    public function test2StartStopSuccess(): void
    {
        pcntl_signal(SIGTERM, SIG_IGN, false);

        self::bootKernel();
        $application = new Application(self::$kernel);

        // Start
        $cmd = $application->find('server:start');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute(['--detach' => true]);

        // Stop
        sleep(1);
        $cmd = $application->find('server:stop');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute([]);
        $this->assertStringContainsString('Swoole HTTP Server is Stopped', $cmdTester->getDisplay());
        sleep(1);
    }
}
