<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Functional\Schema;

use Doctrine\DBAL\Exception;
use Doctrine\DBAL\Schema\AbstractSchemaManager;
use Doctrine\DBAL\Schema\Comparator;
use Doctrine\DBAL\Schema\Table;
use Doctrine\DBAL\Tests\FunctionalTestCase;
use Doctrine\DBAL\Types\Types;

class ColumnRenameTest extends FunctionalTestCase
{
    private AbstractSchemaManager $schemaManager;

    private Comparator $comparator;

    /** @throws Exception */
    protected function setUp(): void
    {
        $this->schemaManager = $this->connection->createSchemaManager();
        $this->comparator    = $this->schemaManager->createComparator();
    }

    /** @throws Exception */
    public function testRenameColumnInIndex(): void
    {
        $this->testRenameColumn(static function (Table $table): void {
            $table->addIndex(['c1', 'c2'], 'idx_c1_c2');
        });
    }

    /** @throws Exception */
    public function testRenameColumnInForeignKeyConstraint(): void
    {
        $this->dropTableIfExists('rename_column_referenced');

        $referencedTable = new Table('rename_column_referenced');
        $referencedTable->addColumn('c1', Types::INTEGER);
        $referencedTable->addColumn('c2', Types::INTEGER);

        // PostgreSQL requires a unique constraint on the referenced table columns
        $referencedTable->addUniqueConstraint(['c1', 'c2']);

        $this->connection->createSchemaManager()->createTable($referencedTable);

        $this->testRenameColumn(static function (Table $table): void {
            $table->addForeignKeyConstraint('rename_column_referenced', ['c1', 'c2'], ['c1', 'c2'], [], 'fk_c1_c2');
        });
    }

    /**
     * @param callable(Table): void $modifier
     *
     * @throws Exception
     */
    private function testRenameColumn(callable $modifier): void
    {
        $this->dropTableIfExists('rename_column');

        $table = new Table('rename_column');
        $table->addColumn('c1', Types::INTEGER);
        $table->addColumn('c2', Types::INTEGER);
        $modifier($table);
        $table->renameColumn('c1', 'c1a');

        $this->connection->createSchemaManager()->createTable($table);

        self::assertTrue($this->comparator->compareTables(
            $table,
            $this->schemaManager->introspectTable('rename_column'),
        )->isEmpty());
    }
}
