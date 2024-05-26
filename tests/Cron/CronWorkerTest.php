<?php

namespace Cesurapp\SwooleBundle\Tests\Cron;

use Cesurapp\SwooleBundle\Cron\CronWorker;
use Cesurapp\SwooleBundle\Tests\_App\Cron\AcmeCron;
use Cesurapp\SwooleBundle\Tests\Kernel;
use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Console\Tester\CommandTester;

class CronWorkerTest extends KernelTestCase
{
    protected function setUp(): void
    {
        $_SERVER['KERNEL_CLASS'] = Kernel::class;
    }

    public function testCronWorker(): void
    {
        $this->assertTrue(self::getContainer()->has(CronWorker::class));

        /** @var CronWorker $worker */
        $worker = self::getContainer()->get(CronWorker::class);

        try {
            $worker->run();
        } catch (\Exception $exception) {
            $this->throwException($exception);
        }
    }

    public function testCronServiceLocator(): void
    {
        /** @var CronWorker $worker */
        $worker = self::getContainer()->get(CronWorker::class);

        $this->assertSame($worker->get(AcmeCron::class)->TIME, '@EveryMinute');
    }

    public function testCronProcess(): void
    {
        /** @var CronWorker $worker */
        $worker = self::getContainer()->get(CronWorker::class);
        $logger = self::getContainer()->get('logger');
        $logger->enableDebug();
        $worker->run();

        $this->assertTrue(str_contains(json_encode($logger->getLogs()), 'Cron Job Process:'));
        $this->assertTrue(str_contains(json_encode($logger->getLogs()), 'Cron Job Finish:'));
    }

    public function testCronListCommand(): void
    {
        static::bootKernel();
        $application = new Application(self::$kernel);

        $cmd = $application->find('cron:list');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute([]);
        $cmdTester->assertCommandIsSuccessful();
        $this->assertStringContainsString('AcmeCron', $cmdTester->getDisplay());
    }

    public function testCronRunManuel(): void
    {
        static::bootKernel();
        $application = new Application(self::$kernel);

        $cmd = $application->find('cron:run');
        $cmdTester = new CommandTester($cmd);
        $this->expectOutputString('Acme Cron');
        $cmdTester->execute(['class' => 'AcmeCron']);
        $cmdTester->assertCommandIsSuccessful();
    }
}
