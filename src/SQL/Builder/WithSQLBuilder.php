<?php

declare(strict_types=1);

namespace Doctrine\DBAL\SQL\Builder;

use Doctrine\DBAL\Query\With;

use function array_merge;
use function count;
use function implode;

final class WithSQLBuilder
{
    public function buildSQL(With $firstExpression, With ...$otherExpressions): string
    {
        $withParts = [];

        foreach (array_merge([$firstExpression], $otherExpressions) as $part) {
            $withPart = [$part->name];
            if (count($part->columns) > 0) {
                $withPart[] = '(' . implode(', ', $part->columns) . ')';
            }

            $withPart[]  = ' AS (' . $part->query . ')';
            $withParts[] = implode('', $withPart);
        }

        return 'WITH ' . implode(', ', $withParts);
    }
}
