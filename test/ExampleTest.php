<?php
use PHPUnit\Framework\TestCase;

class PMTest extends TestCase
{
    public function testOne()
    {        
        $this->assertEquals(0, 0);
    }

    public function testTwo()
    {
        $arr1 = [
            "apple" => "fruit",
            "mango" => "fruit"
        ];
        $arr2 = [
            "apple" => "fruit",
            "berries" => "fruit"
        ];
        $this->assertJsonStringEqualsJsonString(json_encode($arr1), json_encode($arr2), "Json not equal");
    }
    public function testThree()
    {
        $arr = [
            "apple" => "fruit",
            "berries" => "fruit"
        ];
        $this->assertJsonStringEqualsJsonFile('fruit.json', json_encode($arr));
    }
}
