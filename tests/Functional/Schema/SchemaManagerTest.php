<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Functional\Schema;

use Doctrine\DBAL\Exception;
use Doctrine\DBAL\Schema\AbstractSchemaManager;
use Doctrine\DBAL\Schema\Comparator;
use Doctrine\DBAL\Schema\Table;
use Doctrine\DBAL\Tests\FunctionalTestCase;
use Doctrine\DBAL\Types\Types;

use function array_merge;

final class SchemaManagerTest extends FunctionalTestCase
{
    private AbstractSchemaManager $schemaManager;

    /** @throws Exception */
    protected function setUp(): void
    {
        $this->schemaManager = $this->connection->createSchemaManager();
    }

    /**
     * @param callable(AbstractSchemaManager):Comparator $comparatorFactory
     *
     * @dataProvider dataEmptyDiffRegardlessOfForeignTableQuotes
     */
    public function testEmptyDiffRegardlessOfForeignTableQuotes(
        callable $comparatorFactory,
        string $foreignTableName
    ): void {
        if (! $this->connection->getDatabasePlatform()->supportsSchemas()) {
            self::markTestSkipped('Platform does not support schemas.');
        }

        $this->dropAndCreateSchema('other_schema');

        $tableForeign = new Table($foreignTableName);
        $tableForeign->addColumn('id', 'integer');
        $tableForeign->setPrimaryKey(['id']);
        $this->dropAndCreateTable($tableForeign);

        $tableTo = new Table('other_schema.other_table');
        $tableTo->addColumn('id', 'integer');
        $tableTo->addColumn('user_id', 'integer');
        $tableTo->setPrimaryKey(['id']);
        $tableTo->addForeignKeyConstraint($tableForeign, ['user_id'], ['id']);
        $this->dropAndCreateTable($tableTo);

        $schemaFrom = $this->schemaManager->introspectSchema();
        $tableFrom  = $schemaFrom->getTable('other_schema.other_table');

        $diff = $comparatorFactory($this->schemaManager)->compareTables($tableFrom, $tableTo);
        self::assertTrue($diff->isEmpty());
    }

    /** @return iterable<mixed[]> */
    public static function dataEmptyDiffRegardlessOfForeignTableQuotes(): iterable
    {
        foreach (ComparatorTestUtils::comparatorProvider() as $comparatorArguments) {
            foreach (
                [
                    'unquoted' => ['other_schema.user'],
                    'partially quoted' => ['other_schema."user"'],
                    'fully quoted' => ['"other_schema"."user"'],
                ] as $testArguments
            ) {
                yield array_merge($comparatorArguments, $testArguments);
            }
        }
    }

    /**
     * @param callable(AbstractSchemaManager):Comparator $comparatorFactory
     *
     * @dataProvider dataDropIndexInAnotherSchema
     */
    public function testDropIndexInAnotherSchema(callable $comparatorFactory, string $tableName): void
    {
        if (! $this->connection->getDatabasePlatform()->supportsSchemas()) {
            self::markTestSkipped('Platform does not support schemas.');
        }

        $this->dropAndCreateSchema('other_schema');
        $this->dropAndCreateSchema('case');

        $tableFrom = new Table($tableName);
        $tableFrom->addColumn('id', Types::INTEGER);
        $tableFrom->addColumn('name', Types::STRING);
        $tableFrom->addUniqueIndex(['name'], 'some_table_name_unique_index');
        $this->dropAndCreateTable($tableFrom);

        $tableTo = clone $tableFrom;
        $tableTo->dropIndex('some_table_name_unique_index');

        $diff = $comparatorFactory($this->schemaManager)->compareTables($tableFrom, $tableTo);
        self::assertNotFalse($diff);

        $this->schemaManager->alterTable($diff);
        $tableFinal = $this->schemaManager->introspectTable($tableName);
        self::assertEmpty($tableFinal->getIndexes());
    }

    /** @return iterable<mixed[]> */
    public static function dataDropIndexInAnotherSchema(): iterable
    {
        foreach (ComparatorTestUtils::comparatorProvider() as $comparatorScenario => $comparatorArguments) {
            foreach (
                [
                    'default schema' => ['some_table'],
                    'unquoted schema' => ['other_schema.some_table'],
                    'quoted schema' => ['"other_schema".some_table'],
                    'reserved schema' => ['case.some_table'],
                ] as $testScenario => $testArguments
            ) {
                yield $comparatorScenario . ' - ' . $testScenario => array_merge($comparatorArguments, $testArguments);
            }
        }
    }
}
