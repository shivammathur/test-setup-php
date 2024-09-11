<?php

use Cesurapp\SwooleBundle\Runtime\Runtime;

if (PHP_SAPI === 'cli') {
    $_SERVER['APP_RUNTIME'] = Runtime::class;
    Swoole\Coroutine::set(
        ['hook_flags' => SWOOLE_HOOK_TCP | SWOOLE_HOOK_PROC | SWOOLE_HOOK_NATIVE_CURL | SWOOLE_HOOK_SLEEP | SWOOLE_HOOK_FILE]
    );
}
