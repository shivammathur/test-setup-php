<?php

namespace Cesurapp\SwooleBundle\Command;

use Cesurapp\SwooleBundle\Runtime\SwooleProcess;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\DependencyInjection\ParameterBag\ParameterBagInterface;

#[AsCommand(name: 'server:start', description: 'Start Swoole Server')]
class ServerStartCommand extends Command
{
    public function __construct(private readonly ParameterBagInterface $bag)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addOption('detach', 'd', InputOption::VALUE_OPTIONAL, 'Background mode.', false);
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $output = new SymfonyStyle($input, $output);
        $server = new SwooleProcess($output, $this->bag->get('kernel.project_dir'), $this->bag->get('swoole.entrypoint'));
        $server->start(PHP_BINARY, $input->getOption('detach'));
        sleep(1);

        return Command::SUCCESS;
    }
}
