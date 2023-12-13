<?php

namespace Cesurapp\SwooleBundle\Task;

interface TaskInterface
{
    public function __invoke(string $data): mixed;
}
