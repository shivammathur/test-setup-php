<?php

namespace Cesurapp\SwooleBundle\Tests\Task;

use Cesurapp\SwooleBundle\Cron\CronWorker;
use Cesurapp\SwooleBundle\Entity\FailedTask;
use Cesurapp\SwooleBundle\Task\TaskWorker;
use Cesurapp\SwooleBundle\Tests\_App\Task\AcmeFailedTask;
use Cesurapp\SwooleBundle\Tests\_App\Task\AcmeTask;
use Cesurapp\SwooleBundle\Tests\Kernel;
use Doctrine\ORM\Tools\SchemaTool;
use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Console\Tester\CommandTester;
use Symfony\Component\HttpKernel\KernelInterface;

class TaskWorkerTest extends KernelTestCase
{
    protected function setUp(): void
    {
        $_SERVER['KERNEL_CLASS'] = Kernel::class;
    }

    public function testTaskWorker(): void
    {
        $this->assertTrue(self::getContainer()->has(TaskWorker::class));

        /** @var TaskWorker $worker */
        $worker = self::getContainer()->get(TaskWorker::class);

        try {
            $worker->getAll();
        } catch (\Exception $exception) {
            $this->throwException($exception);
        }
    }

    public function testTaskServiceLocator(): void
    {
        /** @var TaskWorker $worker */
        $worker = self::getContainer()->get(TaskWorker::class);

        $this->assertInstanceOf(AcmeTask::class, $worker->getTask(['class' => AcmeTask::class, 'payload' => 'Acme']));
    }

    public function testTaskProcess(): void
    {
        /** @var TaskWorker $worker */
        $worker = self::getContainer()->get(TaskWorker::class);
        $logger = self::getContainer()->get('logger');
        $logger->enableDebug();

        $worker->handle(['class' => AcmeTask::class, 'payload' => serialize('Acme')]);
        $this->expectOutputString('Acme');
        $this->assertTrue(str_contains(json_encode($logger->getLogs()), 'Success Task:'));
    }

    public function testTaskFailedRegister(): void
    {
        /** @var TaskWorker $worker */
        $worker = self::getContainer()->get(TaskWorker::class);
        $logger = self::getContainer()->get('logger');
        $logger->enableDebug();

        $this->initDatabase(self::$kernel);
        $worker->handle(['class' => AcmeFailedTask::class, 'payload' => serialize('AcmeData')]);

        $this->assertTrue(str_contains(json_encode($logger->getLogs()), 'Failed Task:'));
    }

    public function testTaskFailedCronProcess(): void
    {
        /** @var TaskWorker $worker */
        $worker = self::getContainer()->get(TaskWorker::class);
        $logger = self::getContainer()->get('logger');
        $logger->enableDebug();

        // Failed Task
        $this->initDatabase(self::$kernel);
        $worker->handle(['class' => AcmeFailedTask::class, 'payload' => serialize('AcmeData')]);
        $this->assertTrue(str_contains(json_encode($logger->getLogs()), 'Failed Task:'));

        // Re Run Failed Task with Cron Process
        $worker = self::getContainer()->get(CronWorker::class);
        $worker->run();

        $this->assertTrue(str_contains(json_encode($logger->getLogs()), 'Cron Job Process:'));
        $this->assertTrue(str_contains(json_encode($logger->getLogs()), 'Cron Job Finish:'));

        $em = self::getContainer()->get('doctrine')->getManager();
        /** @var FailedTask $failedTask */
        $failedTask = $em->getRepository(FailedTask::class)->findAll()[0];
        $this->assertSame($failedTask->getException(), 'acme task exception');
        $this->assertSame($failedTask->getPayload(), serialize('AcmeData'));
    }

    public function testFailedCreate(): void
    {
        $worker = self::getContainer()->get(TaskWorker::class);

        // Init DB
        $this->initDatabase(self::$kernel);

        /* @var TaskWorker $worker */
        $worker->handle([
            'class' => 'TestTaskClass',
            'data' => [],
        ]);

        $this->assertGreaterThanOrEqual(1, self::getContainer()->get('doctrine')->getRepository(FailedTask::class)->count([]));
    }

    public function testFailedClearCommand(): void
    {
        $worker = self::getContainer()->get(TaskWorker::class);

        // Init DB
        $this->initDatabase(self::$kernel);

        /* @var TaskWorker $worker */
        $worker->handle([
            'class' => 'TestTaskClass',
            'data' => [],
        ]);

        $application = new Application(self::$kernel);
        $cmd = $application->find('task:failed:clear');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute([]);
        $cmdTester->assertCommandIsSuccessful();

        $this->assertGreaterThanOrEqual(0, self::getContainer()->get('doctrine')->getRepository(FailedTask::class)->count([]));
    }

    public function testFailedViewCommand(): void
    {
        $worker = self::getContainer()->get(TaskWorker::class);

        // Init DB
        $this->initDatabase(self::$kernel);

        /* @var TaskWorker $worker */
        $worker->handle([
            'class' => 'TestTaskClass',
            'data' => [],
        ]);

        $application = new Application(self::$kernel);

        $cmd = $application->find('task:failed:view');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute([]);
        $cmdTester->assertCommandIsSuccessful();
        $this->assertStringContainsString('TestTaskClass', $cmdTester->getDisplay());
    }

    public function testTaskListCommand(): void
    {
        self::bootKernel();
        $application = new Application(self::$kernel);

        $cmd = $application->find('task:list');
        $cmdTester = new CommandTester($cmd);
        $cmdTester->execute([]);
        $cmdTester->assertCommandIsSuccessful();
        $this->assertStringContainsString('AcmeFailedTask', $cmdTester->getDisplay());
        $this->assertStringContainsString('AcmeTask', $cmdTester->getDisplay());
    }

    private function initDatabase(KernelInterface $kernel): void
    {
        if ('test' !== $kernel->getEnvironment()) {
            throw new \LogicException('Execution only in Test environment possible!');
        }

        $entityManager = $kernel->getContainer()->get('doctrine')->getManager();
        $metaData = $entityManager->getMetadataFactory()->getAllMetadata();
        $schemaTool = new SchemaTool($entityManager);
        $schemaTool->dropDatabase();
        $schemaTool->updateSchema($metaData);
    }
}
