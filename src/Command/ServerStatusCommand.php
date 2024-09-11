<?php

namespace Cesurapp\SwooleBundle\Command;

use Swoole\Client;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\ConsoleOutputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;

#[AsCommand(name: 'server:status', description: 'Status Swoole Server')]
class ServerStatusCommand extends Command
{
    protected function configure(): void
    {
        $this->addOption('tail', 't', InputOption::VALUE_OPTIONAL, 'Tail mode, default true', true);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        if ($output instanceof ConsoleOutputInterface) {
            $section = $output->section();
        }

        $output = new SymfonyStyle($input, $section ?? $output);
        $client = new Client(SWOOLE_SOCK_TCP);

        while (true) {
            try {
                if (!$client->isConnected()) {
                    @$client->connect('127.0.0.1', 9502, 1.5);
                } else {
                    $client->send('getMetrics');
                    $data = json_decode($client->recv(), true, 512, JSON_THROW_ON_ERROR);
                    if (isset($section)) {
                        $section->clear();
                    }
                    $table = $output->createTable();

                    $table->setRows([
                        ['Environment', $data['server']['env']],
                        ['Host', $data['server']['http']['host'].':'.$data['server']['http']['port']],
                        ['TCP Host', '127.0.0.1:9502'],
                        ['Cron Worker', $data['server']['worker']['cron'] ? 'True' : 'False'],
                        ['Task Worker', $data['server']['worker']['task'] ? 'True' : 'False'],

                        // HTTP
                        ['--HTTP--'],
                        ['Worker Count', $data['metrics']['worker_num']],
                        ['Worker Idle', $data['metrics']['idle_worker_num']],
                        ['Active Connection', $data['metrics']['connection_num']],

                        // Task
                        ['--Task--'],
                        ['Task Worker Count', $data['metrics']['task_worker_num']],
                        ['Task Worker Idle', $data['metrics']['task_idle_worker_num']],
                        ['Task Processing Count', $data['metrics']['tasking_num']],

                        // Coroutine
                        ['--Coroutine--'],
                        ['Coroutine Count', $data['metrics']['coroutine_num']],
                        ['Coroutine Peek Count', $data['metrics']['coroutine_peek_num']],
                    ]);
                    $table->render();

                    if (!$input->getOption('tail')) {
                        return Command::SUCCESS;
                    }
                }
            } catch (\Exception $exception) {
                if (isset($section)) {
                    $section->clear();
                }
                $output->error("Could not connect to server!\n".$exception->getMessage());
                $client = new Client(SWOOLE_SOCK_TCP);
            }

            usleep(1500000);
        }
    }
}
