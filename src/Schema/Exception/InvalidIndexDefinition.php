<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Schema\Exception;

use Doctrine\DBAL\Schema\SchemaException;
use LogicException;

use function sprintf;

final class InvalidIndexDefinition extends LogicException implements SchemaException
{
    public static function nameNotSet(): self
    {
        return new self('Index name is not set.');
    }

    public static function columnsNotSet(): self
    {
        return new self('Index column names are not set.');
    }

    public static function fromNonPositiveColumnLength(int $length): self
    {
        return new self(sprintf('Indexed column length must be a positive integer, %d given.', $length));
    }
}
