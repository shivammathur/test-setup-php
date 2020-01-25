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
        $this->assertEquals(0, 1);
    }    

    public function testThree()
    {                
		$this->markTestSkipped('skip');
		$this->assertEquals(0, 1);
    }

    public function testFour()
    {        
        $this->assertEquals(0, 1);
    }  

    public function testFive()
    {        
        $this->assertEquals(0, 0);
    }  

    public function testSix()
    {        
		$this->markTestSkipped('skip');
		$this->assertEquals(0, 1);
    }           
}
