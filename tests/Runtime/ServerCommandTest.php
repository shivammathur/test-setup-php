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

    public function testStopFail(): void
    {
        self::bootKernel();
        $application = new Application(self::$kernel);

        $cmd = $application->find('server:stop');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute([]);
        $this->assertStringContainsString('Swoole HTTP server not found!', $cmdTester->getDisplay());
    }

    public function testStartStopSuccess(): void
    {
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

    public function testStatus(): void
    {
        self::bootKernel();
        $application = new Application(self::$kernel);

        // Start
        sleep(1);
        $cmd = $application->find('server:start');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute(['--detach' => true]);

        // Status
        $cmd = $application->find('server:status');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute(['--tail' => false]);
        $this->assertStringContainsString('Version', $cmdTester->getDisplay());
        $this->assertStringContainsString('Cron Worker', $cmdTester->getDisplay());
        $this->assertStringContainsString('Task Worker', $cmdTester->getDisplay());

        // Stop
        $cmd = $application->find('server:stop');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute([]);
        $this->assertStringContainsString('Swoole HTTP Server is Stopped', $cmdTester->getDisplay());
        sleep(1);
    }
}
