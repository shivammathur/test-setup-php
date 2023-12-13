<?php

namespace Cesurapp\SwooleBundle\Command;

use Cesurapp\SwooleBundle\Runtime\SwooleProcess;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\DependencyInjection\ParameterBag\ParameterBagInterface;

#[AsCommand(name: 'server:watch', description: 'Watch Swoole Server')]
class ServerWatchCommand extends Command
{
    public function __construct(private readonly ParameterBagInterface $bag)
    {
        parent::__construct();
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $output = new SymfonyStyle($input, $output);
        $server = new SwooleProcess($output, $this->bag->get('kernel.project_dir'), $this->bag->get('swoole.entrypoint'));
        $server->watch(
            explode(',', $this->bag->get('swoole.watch_dir')),
            explode(',', $this->bag->get('swoole.watch_extension'))
        );

        return Command::SUCCESS;
    }
}
