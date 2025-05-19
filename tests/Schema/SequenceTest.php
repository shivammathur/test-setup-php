<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Schema;

use Doctrine\DBAL\Exception;
use Doctrine\DBAL\Schema\Column;
use Doctrine\DBAL\Schema\Name\Identifier;
use Doctrine\DBAL\Schema\PrimaryKeyConstraint;
use Doctrine\DBAL\Schema\Sequence;
use Doctrine\DBAL\Schema\Table;
use Doctrine\DBAL\Types\Types;
use Doctrine\Deprecations\PHPUnit\VerifyDeprecations;
use PHPUnit\Framework\TestCase;

class SequenceTest extends TestCase
{
    use VerifyDeprecations;

    public function testIsAutoincrementFor(): void
    {
        $table = Table::editor()
            ->setUnquotedName('foo')
            ->setColumns(
                Column::editor()
                    ->setUnquotedName('id')
                    ->setTypeName(Types::INTEGER)
                    ->setAutoincrement(true)
                    ->create(),
            )
            ->setPrimaryKeyConstraint(
                PrimaryKeyConstraint::editor()
                    ->setUnquotedColumnNames('id')
                    ->create(),
            )
            ->create();

        $sequence  = new Sequence('foo_id_seq');
        $sequence2 = new Sequence('bar_id_seq');
        $sequence3 = new Sequence('other.foo_id_seq');

        self::assertTrue($sequence->isAutoIncrementsFor($table));
        self::assertFalse($sequence2->isAutoIncrementsFor($table));
        self::assertFalse($sequence3->isAutoIncrementsFor($table));
    }

    public function testIsAutoincrementForCaseInsensitive(): void
    {
        $table = Table::editor()
            ->setUnquotedName('foo')
            ->setColumns(
                Column::editor()
                    ->setUnquotedName('ID')
                    ->setTypeName(Types::INTEGER)
                    ->setAutoincrement(true)
                    ->create(),
            )
            ->setPrimaryKeyConstraint(
                PrimaryKeyConstraint::editor()
                    ->setUnquotedColumnNames('ID')
                    ->create(),
            )
            ->create();

        $sequence  = new Sequence('foo_id_seq');
        $sequence1 = new Sequence('foo_ID_seq');
        $sequence2 = new Sequence('bar_id_seq');
        $sequence3 = new Sequence('bar_ID_seq');
        $sequence4 = new Sequence('other.foo_id_seq');

        self::assertTrue($sequence->isAutoIncrementsFor($table));
        self::assertTrue($sequence1->isAutoIncrementsFor($table));
        self::assertFalse($sequence2->isAutoIncrementsFor($table));
        self::assertFalse($sequence3->isAutoIncrementsFor($table));
        self::assertFalse($sequence4->isAutoIncrementsFor($table));
    }

    public function testEmptyName(): void
    {
        $this->expectDeprecationWithIdentifier('https://github.com/doctrine/dbal/pull/6646');

        new Sequence('');
    }

    public function testOverqualifiedName(): void
    {
        $this->expectDeprecationWithIdentifier('https://github.com/doctrine/dbal/pull/6592');

        new Sequence('identity.auth.user_id_seq');
    }

    /** @throws Exception */
    public function testGetUnqualifiedObjectName(): void
    {
        $sequence = new Sequence('user_id_seq');
        $name     = $sequence->getObjectName();

        self::assertEquals(Identifier::unquoted('user_id_seq'), $name->getUnqualifiedName());
        self::assertNull($name->getQualifier());
    }

    /** @throws Exception */
    public function testGetQualifiedObjectName(): void
    {
        $sequence = new Sequence('auth.user_id_seq');
        $name     = $sequence->getObjectName();

        self::assertEquals(Identifier::unquoted('user_id_seq'), $name->getUnqualifiedName());
        self::assertEquals(Identifier::unquoted('auth'), $name->getQualifier());
    }
}
