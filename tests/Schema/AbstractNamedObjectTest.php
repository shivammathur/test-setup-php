<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Schema;

use Doctrine\DBAL\Schema\AbstractNamedObject;
use Doctrine\DBAL\Schema\Exception\InvalidState;
use Doctrine\DBAL\Schema\Name;
use Doctrine\Deprecations\PHPUnit\VerifyDeprecations;
use PHPUnit\Framework\TestCase;

class AbstractNamedObjectTest extends TestCase
{
    use VerifyDeprecations;

    public function testEmptyName(): void
    {
        $this->expectDeprecationWithIdentifier('https://github.com/doctrine/dbal/pull/6646');

        // @phpstan-ignore expr.resultUnused
        new /** @extends AbstractNamedObject<Name> */
        class ('') extends AbstractNamedObject {
        };
    }

    public function testSetAccessToUninitializedName(): void
    {
        $object = new /** @extends AbstractNamedObject<Name> */
        class ('') extends AbstractNamedObject {
        };

        $this->expectException(InvalidState::class);
        $object->getObjectName();
    }
}
