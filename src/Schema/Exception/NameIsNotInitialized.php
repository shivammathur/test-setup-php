<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Schema\Exception;

use Doctrine\DBAL\Schema\SchemaException;
use LogicException;

final class NameIsNotInitialized extends LogicException implements SchemaException
{
    public static function new(): self
    {
        return new self('Object name has not been initialized.');
    }
}
