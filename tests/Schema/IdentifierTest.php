<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Schema;

use Doctrine\DBAL\Exception;
use Doctrine\DBAL\Schema\Identifier;
use Doctrine\Deprecations\PHPUnit\VerifyDeprecations;
use PHPUnit\Framework\TestCase;

class IdentifierTest extends TestCase
{
    use VerifyDeprecations;

    public function testEmptyName(): void
    {
        $this->expectDeprecationWithIdentifier('https://github.com/doctrine/dbal/pull/6646');

        new Identifier('');
    }

    /** @throws Exception */
    public function testGetObjectName(): void
    {
        $identifier = new Identifier('warehouse.inventory.products.id');
        $name       = $identifier->getObjectName();

        self::assertEquals([
            \Doctrine\DBAL\Schema\Name\Identifier::unquoted('warehouse'),
            \Doctrine\DBAL\Schema\Name\Identifier::unquoted('inventory'),
            \Doctrine\DBAL\Schema\Name\Identifier::unquoted('products'),
            \Doctrine\DBAL\Schema\Name\Identifier::unquoted('id'),
        ], $name->getIdentifiers());
    }
}
