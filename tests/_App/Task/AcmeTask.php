<?php

namespace Cesurapp\SwooleBundle\Tests\_App\Task;

use Cesurapp\SwooleBundle\Task\TaskInterface;

class AcmeTask implements TaskInterface
{
    public function __invoke(string $data): string
    {
        echo $data;

        return 'Acme Task';
    }
}
