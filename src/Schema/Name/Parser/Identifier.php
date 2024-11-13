<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Schema\Name\Parser;

/**
 * Represents an SQL identifier.
 *
 * @internal
 */
final class Identifier
{
    private function __construct(
        private readonly string $value,
        private readonly bool $isQuoted,
    ) {
    }

    public function getValue(): string
    {
        return $this->value;
    }

    public function isQuoted(): bool
    {
        return $this->isQuoted;
    }

    /**
     * Creates a quoted identifier.
     */
    public static function quoted(string $value): self
    {
        return new self($value, true);
    }

    /**
     * Creates an unquoted identifier.
     */
    public static function unquoted(string $value): self
    {
        return new self($value, false);
    }
}
