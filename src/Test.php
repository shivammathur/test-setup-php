<?php

/**
 * For the full copyright and license information, please view
 * the LICENSE file that was distributed with this source code.
 */

declare(strict_types=1);

namespace drupol\testDarwin;

final class Test
{
    public function testCase1()
    {
        return preg_match('/\\\\([^\\\\]+)\s*$/', ' Bunny\Channel', $matches);
    }

    public function testCase2()
    {
        return preg_match('/\\\\([^\\\\]+)\s*$/', ' App\Factories\RabbitMQFactory', $matches);
    }
}
