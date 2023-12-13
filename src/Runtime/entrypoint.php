<?php

use Cesurapp\SwooleBundle\Runtime\Runtime;
use OpenSwoole\Coroutine;

if (PHP_SAPI === 'cli') {
    $_SERVER['APP_RUNTIME'] = Runtime::class;
    Coroutine::set(
        ['hook_flags' => OpenSwoole\Runtime::HOOK_TCP
            | OpenSwoole\Runtime::HOOK_PROC
            | OpenSwoole\Runtime::HOOK_NATIVE_CURL
            | OpenSwoole\Runtime::HOOK_SLEEP,
        ]
    );
}
