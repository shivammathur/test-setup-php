<?php

namespace Cesurapp\SwooleBundle\Tests\_App\Cron;

use Cesurapp\SwooleBundle\Cron\AbstractCronJob;

class AcmeCron extends AbstractCronJob
{
    public string $TIME = '@EveryMinute';

    public function __invoke(): void
    {
        echo 'Acme Cron';
    }
}
