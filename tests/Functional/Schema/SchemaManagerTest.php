<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Functional\Schema;

use Doctrine\DBAL\Exception;
use Doctrine\DBAL\Schema\AbstractSchemaManager;
use Doctrine\DBAL\Schema\Table;
use Doctrine\DBAL\Tests\FunctionalTestCase;
use Doctrine\DBAL\Types\Types;
use Doctrine\Deprecations\PHPUnit\VerifyDeprecations;
use PHPUnit\Framework\Attributes\TestWith;

use function sprintf;

final class SchemaManagerTest extends FunctionalTestCase
{
    use VerifyDeprecations;

    private AbstractSchemaManager $schemaManager;

    /** @throws Exception */
    protected function setUp(): void
    {
        $this->schemaManager = $this->connection->createSchemaManager();
    }

    /** @dataProvider dataEmptyDiffRegardlessOfForeignTableQuotes */
    public function testEmptyDiffRegardlessOfForeignTableQuotes(string $foreignTableName): void
    {
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
        $tableTo->addForeignKeyConstraint($foreignTableName, ['user_id'], ['id']);
        $this->dropAndCreateTable($tableTo);

        $schemaFrom = $this->schemaManager->introspectSchema();
        $tableFrom  = $schemaFrom->getTable('other_schema.other_table');

        $diff = $this->schemaManager->createComparator()->compareTables($tableFrom, $tableTo);
        self::assertTrue($diff->isEmpty());
    }

    /** @return iterable<string,array{string}> */
    public static function dataEmptyDiffRegardlessOfForeignTableQuotes(): iterable
    {
        return [
            'unquoted' => ['other_schema.user'],
            'partially quoted' => ['other_schema."user"'],
            'fully quoted' => ['"other_schema"."user"'],
        ];
    }

    /** @dataProvider dataDropIndexInAnotherSchema */
    public function testDropIndexInAnotherSchema(string $tableName): void
    {
        if (! $this->connection->getDatabasePlatform()->supportsSchemas()) {
            self::markTestSkipped('Platform does not support schemas.');
        }

        $this->dropAndCreateSchema('other_schema');
        $this->dropAndCreateSchema('case');

        $tableFrom = new Table($tableName);
        $tableFrom->addColumn('id', Types::INTEGER);
        $tableFrom->addColumn('name', Types::STRING, ['length' => 32]);
        $tableFrom->addUniqueIndex(['name'], 'some_table_name_unique_index');
        $this->dropAndCreateTable($tableFrom);

        $tableTo = clone $tableFrom;
        $tableTo->dropIndex('some_table_name_unique_index');

        $diff = $this->schemaManager->createComparator()->compareTables($tableFrom, $tableTo);
        self::assertFalse($diff->isEmpty());

        $this->schemaManager->alterTable($diff);
        $tableFinal = $this->schemaManager->introspectTable($tableName);
        self::assertEmpty($tableFinal->getIndexes());
    }

    /** @return iterable<string,array{string}> */
    public static function dataDropIndexInAnotherSchema(): iterable
    {
        return [
            'default schema' => ['some_table'],
            'unquoted schema' => ['other_schema.some_table'],
            'quoted schema' => ['"other_schema".some_table'],
            'reserved schema' => ['case.some_table'],
        ];
    }

    /** @throws Exception */
    #[TestWith([false])]
    #[TestWith([true])]
    public function testIntrospectTableWithDotInName(bool $quoted): void
    {
        $platform = $this->connection->getDatabasePlatform();

        if ($platform->supportsSchemas()) {
            self::markTestIncomplete('DBAL 4.x will fail to introspect this table on a platform that supports schemas');
        }

        $name           = 'example.com';
        $normalizedName = $platform->normalizeUnquotedIdentifier($name);
        $quotedName     = $this->connection->quoteSingleIdentifier($normalizedName);

        // create the table manually since identifiers with dots are not supported in DBAL 4.x
        $sql = sprintf('CREATE TABLE %s (s VARCHAR(16))', $quotedName);

        $this->dropTableIfExists($quotedName);
        $this->connection->executeStatement($sql);

        if ($quoted) {
            $this->expectNoDeprecationWithIdentifier('https://github.com/doctrine/dbal/pull/6768');

            $table = $this->schemaManager->introspectTable($quotedName);
        } else {
            $this->expectDeprecationWithIdentifier('https://github.com/doctrine/dbal/pull/6768');

            $table = $this->schemaManager->introspectTable($name);
        }

        self::assertCount(1, $table->getColumns());
    }

    /** @throws Exception */
    public function testIntrospectTableWithInvalidName(): void
    {
        $table = new Table('"example"');
        $table->addColumn('id', 'integer');

        $this->dropAndCreateTable($table);

        $this->expectDeprecationWithIdentifier('https://github.com/doctrine/dbal/pull/6768');

        $table = $this->schemaManager->introspectTable('"example');
        self::assertCount(1, $table->getColumns());
    }
}
