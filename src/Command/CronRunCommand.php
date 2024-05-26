<?php

namespace Cesurapp\SwooleBundle\Command;

use Cesurapp\SwooleBundle\Cron\CronWorker;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

#[AsCommand(name: 'cron:run', description: 'Runs cron process, one time.')]
class CronRunCommand extends Command
{
    public function __construct(private readonly CronWorker $cronWorker)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addArgument('class', InputArgument::REQUIRED, 'Cron class name.');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $class = $input->getArgument('class');
        $crons = array_filter(iterator_to_array($this->cronWorker->getAll()), static fn ($cron) => str_contains(get_class($cron), $class));
        if (count($crons) > 0) {
            $output->writeln('Cron Job Process: '.get_class($crons[0]));
            $crons[0]();
            $output->writeln('Cron Job Finish: '.get_class($crons[0]));
        } else {
            $output->writeln('Cron job not found!');
        }

        return Command::SUCCESS;
    }
}
