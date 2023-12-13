<?php

namespace Cesurapp\SwooleBundle\Cron;

interface CronInterface
{
    public function __invoke(): void;
}
