<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Schema;

use Doctrine\DBAL\Schema\Exception\InvalidIndexDefinition;
use Doctrine\DBAL\Schema\Index;
use Doctrine\DBAL\Schema\Index\IndexedColumn;
use Doctrine\DBAL\Schema\Name\UnqualifiedName;
use PHPUnit\Framework\Attributes\TestWith;
use PHPUnit\Framework\TestCase;

class IndexEditorTest extends TestCase
{
    public function testNameNotSet(): void
    {
        $editor = Index::editor()
            ->setUnquotedColumnNames('id');

        $this->expectException(InvalidIndexDefinition::class);

        $editor->create();
    }

    public function testColumnsNotSet(): void
    {
        $editor = Index::editor()
            ->setUnquotedName('idx_user_id');

        $this->expectException(InvalidIndexDefinition::class);

        $editor->create();
    }

    public function testSetUnquotedName(): void
    {
        $index = Index::editor()
            ->setUnquotedName('idx_id')
            ->setColumnNames($this->createColumnName())
            ->create();

        self::assertEquals(
            UnqualifiedName::unquoted('idx_id'),
            $index->getObjectName(),
        );
    }

    public function testSetQuotedName(): void
    {
        $index = Index::editor()
            ->setQuotedName('idx_id')
            ->setColumnNames($this->createColumnName())
            ->create();

        self::assertEquals(
            UnqualifiedName::quoted('idx_id'),
            $index->getObjectName(),
        );
    }

    public function testSetUnquotedColumnNames(): void
    {
        $index = Index::editor()
            ->setName($this->createName())
            ->setUnquotedColumnNames('account_id', 'user_id')
            ->create();

        self::assertEquals([
            new IndexedColumn(UnqualifiedName::unquoted('account_id'), null),
            new IndexedColumn(UnqualifiedName::unquoted('user_id'), null),
        ], $index->getIndexedColumns());
    }

    public function testSetQuotedColumnNames(): void
    {
        $index = Index::editor()
            ->setName($this->createName())
            ->setQuotedColumnNames('account_id', 'user_id')
            ->create();

        self::assertEquals([
            new IndexedColumn(UnqualifiedName::quoted('account_id'), null),
            new IndexedColumn(UnqualifiedName::quoted('user_id'), null),
        ], $index->getIndexedColumns());
    }

    public function testPreservesRegularIndexProperties(): void
    {
        $index1 = new Index(
            'idx_user_name',
            ['user_name'],
            false,
            false,
            [],
            [
                'lengths' => [32],
                'where' => 'is_active = 1',
            ],
        );

        $index2 = $index1->edit()
            ->create();

        self::assertSame('idx_user_name', $index2->getName());
        self::assertSame(['user_name'], $index2->getColumns());
        self::assertFalse($index2->isUnique());
        self::assertFalse($index2->isPrimary());
        self::assertSame([], $index2->getFlags());
        self::assertSame([
            'lengths' => [32],
            'where' => 'is_active = 1',
        ], $index2->getOptions());
    }

    /** @param array<string> $flags */
    #[TestWith([['fulltext']])]
    #[TestWith([['spatial']])]
    #[TestWith([['clustered']])]
    public function testPreservesIndexFlags(array $flags): void
    {
        $index1 = new Index(
            'idx_test',
            ['test'],
            false,
            false,
            $flags,
        );

        $index2 = $index1->edit()
            ->create();

        self::assertSame($flags, $index2->getFlags());
    }

    private function createName(): UnqualifiedName
    {
        return UnqualifiedName::unquoted('idx');
    }

    private function createColumnName(): UnqualifiedName
    {
        return UnqualifiedName::unquoted('id');
    }
}
