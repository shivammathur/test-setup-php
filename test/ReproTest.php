<?php

use PHPUnit\Framework\TestCase;

class ReproTest extends TestCase
{
    public function testDebugMagicMethod()
    {
        ob_start();
        var_dump(new ClassA());

        $this->assertRegExp('/\["a"]=>\s+string\(1\) "b"/', ob_get_clean());
    }
}

class ClassA
{
    public function __debugInfo() {
        return ['a' => 'b'];
    }
}
