<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests\Functional\Schema;

use Doctrine\DBAL\Exception;
use Doctrine\DBAL\Schema\AbstractSchemaManager;
use Doctrine\DBAL\Schema\Comparator;
use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Schema\Table;
use Doctrine\DBAL\Tests\FunctionalTestCase;

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

        $this->dropTableIfExists('other_schema.other_table');
        $this->dropTableIfExists('other_schema."user"');
        $this->dropSchemaIfExists('other_schema');

        $tableForeign = new Table($foreignTableName);
        $tableForeign->addColumn('id', 'integer');
        $tableForeign->setPrimaryKey(['id']);

        $tableTo = new Table('other_schema.other_table');
        $tableTo->addColumn('id', 'integer');
        $tableTo->addColumn('user_id', 'integer');
        $tableTo->setPrimaryKey(['id']);
        $tableTo->addForeignKeyConstraint($tableForeign, ['user_id'], ['id'], []);

        $schemaTo = new Schema([$tableForeign, $tableTo]);
        $this->schemaManager->createSchemaObjects($schemaTo);

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
}
