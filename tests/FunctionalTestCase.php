<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Tests;

use Doctrine\DBAL\Connection;
use Doctrine\DBAL\Exception;
use Doctrine\DBAL\Exception\DatabaseObjectNotFoundException;
use Doctrine\DBAL\Platforms\Exception\NotSupported;
use Doctrine\DBAL\Schema\Identifier;
use Doctrine\DBAL\Schema\Schema;
use Doctrine\DBAL\Schema\Table;
use PHPUnit\Framework\Attributes\After;
use PHPUnit\Framework\Attributes\Before;
use PHPUnit\Framework\TestCase;

use function count;

abstract class FunctionalTestCase extends TestCase
{
    /**
     * Shared connection when a TestCase is run alone (outside of it's functional suite)
     */
    private static ?Connection $sharedConnection = null;

    protected Connection $connection;

    /**
     * Whether the shared connection could be reused by subsequent tests.
     */
    private bool $isConnectionReusable = true;

    /**
     * Mark shared connection not reusable for subsequent tests.
     *
     * Should be called by the tests that modify configuration
     * or alter the connection state in another way that may impact other tests.
     */
    protected function markConnectionNotReusable(): void
    {
        $this->isConnectionReusable = false;
    }

    #[Before]
    final protected function connect(): void
    {
        if (self::$sharedConnection === null) {
            self::$sharedConnection = TestUtil::getConnection();
        }

        $this->connection = self::$sharedConnection;
    }

    #[After]
    final protected function disconnect(): void
    {
        while ($this->connection->isTransactionActive()) {
            $this->connection->rollBack();
        }

        if ($this->isConnectionReusable) {
            return;
        }

        if (self::$sharedConnection !== null) {
            self::$sharedConnection->close();
            self::$sharedConnection = null;
        }

        // Make sure the connection is no longer available to the test.
        // Otherwise, there is a chance that a teardown method of the test will reconnect
        // (e.g. to drop a table), and then this reopened connection will remain open and attached to the PHPUnit result
        // until the end of the suite leaking connection resources, while subsequent tests will use
        // the newly established shared connection.
        unset($this->connection);

        $this->isConnectionReusable = true;
    }

    /**
     * Drops the table with the specified name, if it exists.
     *
     * @throws Exception
     */
    public function dropTableIfExists(string $name): void
    {
        $schemaManager = $this->connection->createSchemaManager();

        try {
            $schemaManager->dropTable($name);
        } catch (DatabaseObjectNotFoundException) {
        }
    }

    /**
     * Drops and creates a new table.
     *
     * @throws Exception
     */
    public function dropAndCreateTable(Table $table): void
    {
        $schemaManager = $this->connection->createSchemaManager();
        $platform      = $this->connection->getDatabasePlatform();
        $tableName     = $table->getQuotedName($platform);

        $this->dropTableIfExists($tableName);
        $schemaManager->createTable($table);
    }

    /**
     * Drops the schema with the specified name, if it exists.
     *
     * @throws Exception
     */
    public function dropSchemaIfExists(string $schemaName): void
    {
        $platform = $this->connection->getDatabasePlatform();
        if (! $platform->supportsSchemas()) {
            throw NotSupported::new(__METHOD__);
        }

        $schemaName     = (new Identifier($schemaName))->getName();
        $schemaManager  = $this->connection->createSchemaManager();
        $databaseSchema = $schemaManager->introspectSchema();

        $sequencesToDrop = [];
        foreach ($databaseSchema->getSequences() as $sequence) {
            if ($sequence->getNamespaceName() !== $schemaName) {
                continue;
            }

            $sequencesToDrop[] = $sequence;
        }

        $tablesToDrop = [];
        foreach ($databaseSchema->getTables() as $table) {
            if ($table->getNamespaceName() !== $schemaName) {
                continue;
            }

            $tablesToDrop[] = $table;
        }

        if (count($sequencesToDrop) > 0 || count($tablesToDrop) > 0) {
            $schemaManager->dropSchemaObjects(new Schema($tablesToDrop, $sequencesToDrop));
        }

        try {
            $quotedSchemaName = (new Identifier($schemaName))->getQuotedName($platform);
            $schemaManager->dropSchema($quotedSchemaName);
        } catch (DatabaseObjectNotFoundException) {
        }
    }

    /**
     * Drops and creates a new schema.
     *
     * @throws Exception
     */
    public function dropAndCreateSchema(string $schemaName): void
    {
        $platform = $this->connection->getDatabasePlatform();
        if (! $platform->supportsSchemas()) {
            throw NotSupported::new(__METHOD__);
        }

        $schemaManager    = $this->connection->createSchemaManager();
        $quotedSchemaName = (new Identifier($schemaName))->getQuotedName($platform);
        $schemaToCreate   = new Schema([], [], null, [$quotedSchemaName]);

        $this->dropSchemaIfExists($quotedSchemaName);
        $schemaManager->createSchemaObjects($schemaToCreate);
    }
}
