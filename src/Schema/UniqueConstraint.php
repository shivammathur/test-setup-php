<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Schema;

use Doctrine\DBAL\Platforms\AbstractPlatform;
use Doctrine\DBAL\Schema\Exception\InvalidState;
use Doctrine\DBAL\Schema\Name\Parser\UnqualifiedNameParser;
use Doctrine\DBAL\Schema\Name\Parsers;
use Doctrine\DBAL\Schema\Name\UnqualifiedName;
use Doctrine\Deprecations\Deprecation;
use Throwable;

use function array_keys;
use function array_map;
use function count;
use function strtolower;

/**
 * Represents unique constraint definition.
 *
 * @extends AbstractOptionallyNamedObject<UnqualifiedName>
 */
class UniqueConstraint extends AbstractOptionallyNamedObject
{
    /**
     * Asset identifier instances of the column names the unique constraint is associated with.
     *
     * @var array<string, Identifier>
     */
    protected array $columns = [];

    /**
     * Platform specific flags
     *
     * @var array<string, true>
     */
    protected array $flags = [];

    /**
     * Names of the columns covered by the unique constraint.
     *
     * @var list<UnqualifiedName>
     */
    private array $columnNames = [];

    private bool $failedToParseColumnNames = false;

    /**
     * @param array<string>        $columns
     * @param array<string>        $flags
     * @param array<string, mixed> $options
     */
    public function __construct(
        string $name,
        array $columns,
        array $flags = [],
        private readonly array $options = [],
    ) {
        parent::__construct($name);

        foreach ($columns as $column) {
            $this->addColumn($column);
        }

        foreach ($flags as $flag) {
            $this->addFlag($flag);
        }
    }

    protected function getNameParser(): UnqualifiedNameParser
    {
        return Parsers::getUnqualifiedNameParser();
    }

    /**
     * Returns the names of the columns the constraint is associated with.
     *
     * @return non-empty-list<UnqualifiedName>
     */
    public function getColumnNames(): array
    {
        if ($this->failedToParseColumnNames) {
            throw InvalidState::uniqueConstraintHasInvalidColumnNames($this->getName());
        }

        if (count($this->columnNames) < 1) {
            throw InvalidState::uniqueConstraintHasEmptyColumnNames($this->getName());
        }

        return $this->columnNames;
    }

    /** @return list<string> */
    public function getColumns(): array
    {
        return array_keys($this->columns);
    }

    /**
     * Returns the quoted representation of the column names the constraint is associated with.
     *
     * But only if they were defined with one or a column name
     * is a keyword reserved by the platform.
     * Otherwise, the plain unquoted value as inserted is returned.
     *
     * @param AbstractPlatform $platform The platform to use for quotation.
     *
     * @return list<string>
     */
    public function getQuotedColumns(AbstractPlatform $platform): array
    {
        $columns = [];

        foreach ($this->columns as $column) {
            $columns[] = $column->getQuotedName($platform);
        }

        return $columns;
    }

    /** @return array<int, string> */
    public function getUnquotedColumns(): array
    {
        return array_map($this->trimQuotes(...), $this->getColumns());
    }

    /**
     * Returns platform specific flags for unique constraint.
     *
     * @return array<int, string>
     */
    public function getFlags(): array
    {
        return array_keys($this->flags);
    }

    /**
     * Adds flag for a unique constraint that translates to platform specific handling.
     *
     * @return $this
     *
     * @example $uniqueConstraint->addFlag('CLUSTERED')
     */
    public function addFlag(string $flag): self
    {
        $this->flags[strtolower($flag)] = true;

        return $this;
    }

    /**
     * Does this unique constraint have a specific flag?
     */
    public function hasFlag(string $flag): bool
    {
        return isset($this->flags[strtolower($flag)]);
    }

    /**
     * Returns whether the unique constraint is clustered.
     */
    public function isClustered(): bool
    {
        return $this->hasFlag('clustered');
    }

    /**
     * Removes a flag.
     */
    public function removeFlag(string $flag): void
    {
        unset($this->flags[strtolower($flag)]);
    }

    public function hasOption(string $name): bool
    {
        return isset($this->options[strtolower($name)]);
    }

    public function getOption(string $name): mixed
    {
        return $this->options[strtolower($name)];
    }

    /** @return array<string, mixed> */
    public function getOptions(): array
    {
        return $this->options;
    }

    protected function addColumn(string $column): void
    {
        $this->columns[$column] = new Identifier($column);

        $parser = Parsers::getUnqualifiedNameParser();

        try {
            $this->columnNames[] = $parser->parse($column);
        } catch (Throwable $e) {
            $this->failedToParseColumnNames = true;

            Deprecation::trigger(
                'doctrine/dbal',
                'https://github.com/doctrine/dbal/pull/XXXX',
                'Unable to parse column name: %s.',
                $e->getMessage(),
            );
        }
    }
}
