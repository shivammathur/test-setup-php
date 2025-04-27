<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Schema;

use Doctrine\DBAL\Schema\Exception\InvalidTableDefinition;
use Doctrine\DBAL\Schema\Name\OptionallyQualifiedName;
use Doctrine\DBAL\Schema\Table;
use Doctrine\DBAL\Types\Types;
use PHPUnit\Framework\TestCase;

class TableEditorTest extends TestCase
{
    public function testSetName(): void
    {
        $name = OptionallyQualifiedName::unquoted('contacts');

        $table = new Table('accounts');
        $table->addColumn('id', Types::INTEGER);

        $table = $table->edit()
            ->setName($name)
            ->create();

        self::assertEquals($name, $table->getObjectName());
    }

    public function testNameNotSet(): void
    {
        $this->expectException(InvalidTableDefinition::class);

        Table::editor()->create();
    }
}
