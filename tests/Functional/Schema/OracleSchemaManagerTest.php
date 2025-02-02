<?php

namespace Doctrine\DBAL\Tests\Functional\Schema;

use Doctrine\DBAL\Exception\DatabaseObjectNotFoundException;
use Doctrine\DBAL\Platforms\AbstractPlatform;
use Doctrine\DBAL\Platforms\OraclePlatform;
use Doctrine\DBAL\Schema\AbstractSchemaManager;
use Doctrine\DBAL\Schema\Comparator;
use Doctrine\DBAL\Schema\Index;
use Doctrine\DBAL\Schema\Table;
use Doctrine\DBAL\Tests\TestUtil;
use Doctrine\DBAL\Types\BinaryType;
use Doctrine\DBAL\Types\Types;

use function array_map;

class OracleSchemaManagerTest extends SchemaManagerFunctionalTestCase
{
    protected function supportsPlatform(AbstractPlatform $platform): bool
    {
        return $platform instanceof OraclePlatform;
    }

    /**
     * Oracle currently stores VARBINARY columns as RAW (fixed-size)
     */
    protected function assertVarBinaryColumnIsValid(Table $table, string $columnName, int $expectedLength): void
    {
        $column = $table->getColumn($columnName);
        self::assertInstanceOf(BinaryType::class, $column->getType());
        self::assertSame($expectedLength, $column->getLength());
    }

    /**
     * @param callable(AbstractSchemaManager):Comparator $comparatorFactory
     *
     * @dataProvider \Doctrine\DBAL\Tests\Functional\Schema\ComparatorTestUtils::comparatorProvider
     */
    public function testAlterTableColumnNotNull(callable $comparatorFactory): void
    {
        $tableName = 'list_table_column_notnull';
        $table     = new Table($tableName);

        $table->addColumn('id', Types::INTEGER);
        $table->addColumn('foo', Types::INTEGER);
        $table->addColumn('bar', Types::STRING);
        $table->setPrimaryKey(['id']);

        $this->dropAndCreateTable($table);

        $columns = $this->schemaManager->listTableColumns($tableName);

        self::assertTrue($columns['id']->getNotnull());
        self::assertTrue($columns['foo']->getNotnull());
        self::assertTrue($columns['bar']->getNotnull());

        $diffTable = clone $table;
        $diffTable->changeColumn('foo', ['notnull' => false]);
        $diffTable->changeColumn('bar', ['length' => 1024]);

        $diff = $comparatorFactory($this->schemaManager)->diffTable($table, $diffTable);
        self::assertNotFalse($diff);

        $this->schemaManager->alterTable($diff);

        $columns = $this->schemaManager->listTableColumns($tableName);

        self::assertTrue($columns['id']->getNotnull());
        self::assertFalse($columns['foo']->getNotnull());
        self::assertTrue($columns['bar']->getNotnull());
    }

    public function testListTableColumnsSameTableNamesInDifferentSchemas(): void
    {
        $table = $this->createListTableColumns();
        $this->dropAndCreateTable($table);

        $otherTable = new Table($table->getName());
        $otherTable->addColumn('id', Types::STRING);

        $connection    = TestUtil::getPrivilegedConnection();
        $schemaManager = $connection->getSchemaManager();

        try {
            $schemaManager->dropTable($otherTable->getName());
        } catch (DatabaseObjectNotFoundException $e) {
        }

        $schemaManager->createTable($otherTable);
        $connection->close();

        $columns = $this->schemaManager->listTableColumns($table->getName());
        self::assertCount(7, $columns);
    }

    public function testListTableIndexesPrimaryKeyConstraintNameDiffersFromIndexName(): void
    {
        $table = new Table('list_table_indexes_pk_id_test');
        $table->setSchemaConfig($this->schemaManager->createSchemaConfig());
        $table->addColumn('id', Types::INTEGER, ['notnull' => true]);
        $table->addUniqueIndex(['id'], 'id_unique_index');
        $this->dropAndCreateTable($table);

        $this->schemaManager->createIndex(
            new Index('id_pk_id_index', ['id'], true, true),
            'list_table_indexes_pk_id_test',
        );

        $tableIndexes = $this->schemaManager->listTableIndexes('list_table_indexes_pk_id_test');

        self::assertArrayHasKey('primary', $tableIndexes, 'listTableIndexes() has to return a "primary" array key.');
        self::assertEquals(['id'], array_map('strtolower', $tableIndexes['primary']->getColumns()));
        self::assertTrue($tableIndexes['primary']->isUnique());
        self::assertTrue($tableIndexes['primary']->isPrimary());
    }

    public function testListTableDateTypeColumns(): void
    {
        $table = new Table('tbl_date');
        $table->addColumn('col_date', Types::DATE_MUTABLE);
        $table->addColumn('col_datetime', Types::DATETIME_MUTABLE);
        $table->addColumn('col_datetimetz', Types::DATETIMETZ_MUTABLE);

        $this->dropAndCreateTable($table);

        $columns = $this->schemaManager->listTableColumns('tbl_date');

        self::assertSame(Types::DATE_MUTABLE, $columns['col_date']->getType()->getName());
        self::assertSame(Types::DATETIME_MUTABLE, $columns['col_datetime']->getType()->getName());
        self::assertSame(Types::DATETIMETZ_MUTABLE, $columns['col_datetimetz']->getType()->getName());
    }

    public function testCreateAndListSequences(): void
    {
        self::markTestSkipped(
            "Skipped for uppercase letters are contained in sequences' names. Fix the schema manager in 3.0.",
        );
    }

    public function testQuotedTableNameRemainsQuotedInSchema(): void
    {
        $table = new Table('"tester"');
        $table->addColumn('"id"', Types::INTEGER);
        $table->addColumn('"name"', Types::STRING);

        $this->dropAndCreateTable($table);

        $schemaManager = $this->connection->createSchemaManager();

        $fromSchema = $schemaManager->introspectSchema();
        $toSchema   = clone $fromSchema;

        $toSchema->getTable('"tester"')->dropColumn('"name"');
        $diff = $schemaManager->createComparator()
            ->compareSchemas($fromSchema, $toSchema);

        $schemaManager->alterSchema($diff);

        $columns = $schemaManager->listTableColumns('"tester"');
        self::assertCount(1, $columns);
    }
}
