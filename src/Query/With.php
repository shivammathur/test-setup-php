<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Query;

/** @internal */
final class With
{
    /** @param string[] $columns */
    public function __construct(
        public readonly string $name,
        public readonly string|QueryBuilder $query,
        public readonly array $columns = [],
    ) {
    }
}
