<?php

/**
 * For the full copyright and license information, please view
 * the LICENSE file that was distributed with this source code.
 */

declare(strict_types=1);

namespace spec\drupol\testDarwin;

use drupol\testDarwin\Test;
use PhpSpec\ObjectBehavior;

class TestSpec extends ObjectBehavior
{
    public function it_is_initializable()
    {
        $this->shouldHaveType(Test::class);
    }

    public function it_test_testCase1()
    {
        $this
            ->testCase1()
            ->shouldReturn(1);
    }

    public function it_test_testCase2()
    {
        $this
            ->testCase2()
            ->shouldReturn(1);
    }
}
