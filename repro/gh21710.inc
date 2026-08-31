<?php

if (getenv('call_user_func')) {
    eval('class P {}');
}

/* The parent is not in SHM, so this linked method uses a heap op_array copy. */
class C extends P
{
    public static function f($v)
    {
        /* The type change on the next request forces a tracing-JIT side exit. */
        return $v[0];
        if ($a) {
            return 1;
        }
        return 2;
    }
}
