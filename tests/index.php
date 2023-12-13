<?php

use Cesurapp\SwooleBundle\Tests\Kernel;

require_once dirname(__DIR__).'/src/Runtime/entrypoint.php';
require_once dirname(__DIR__).'/vendor/autoload_runtime.php';

return static function (array $context) {
    return new Kernel($context['APP_ENV'], (bool) $context['APP_DEBUG']);
};
