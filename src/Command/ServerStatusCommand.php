<?php

namespace Cesurapp\SwooleBundle\Command;

use OpenSwoole\Constant;
use OpenSwoole\Client;
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
        $client = new Client(Constant::SOCK_TCP);

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
                        ['Version', $data['metrics']['version'], ''],
                        ['Environment', $data['server']['env'], ''],
                        ['Host', $data['server']['http']['host'].':'.$data['server']['http']['port'], ''],
                        ['TCP Host', '127.0.0.1:9502', ''],
                        ['Cron Worker', $data['server']['worker']['cron'] ? 'True' : 'False', ''],
                        ['Task Worker', $data['server']['worker']['task'] ? 'True' : 'False', ''],
                        [
                            'Process ID',
                            'Master > '.$data['metrics']['master_pid'],
                            'Manager > '.$data['metrics']['manager_pid'],
                        ],
                        [
                            'Worker',
                            'Idle > '.$data['metrics']['workers_idle'],
                            'Total > '.$data['metrics']['workers_total'],
                        ],
                        [
                            'Task Worker',
                            'Idle > '.$data['metrics']['task_workers_idle'],
                            'Total > '.$data['metrics']['task_workers_total'],
                            'Queue > '.$data['metrics']['tasking_num'],
                        ],
                        [
                            'Connection',
                            'Max > '.number_format($data['metrics']['max_conn']),
                            'Total > '.number_format($data['metrics']['requests_total']),
                            'Active > '.$data['metrics']['connections_active'],
                        ],
                        [
                            'Cache Table',
                            'Current > '.$data['server']['http']['cache_table']['current'],
                            'Total > '.$data['server']['http']['cache_table']['size'],
                            'Memory Size > '.round((int) $data['server']['http']['cache_table']['memory_size'] / (1024 * 1024), 2).'mb',
                        ],
                        [
                            'Memory',
                            ((int) $data['metrics']['worker_memory_usage'] / (1024 * 1024)).'mb',
                            'VM Object > '.$data['metrics']['worker_vm_object_num'],
                            'VM Resource > '.$data['metrics']['worker_vm_resource_num'],
                        ],
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
                $client = new Client(Constant::SOCK_TCP);
            }

            usleep(1500000);
        }
    }
}
