<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Schema;

use Doctrine\DBAL\Schema\Name\OptionallyQualifiedName;
use Doctrine\DBAL\Schema\Name\Parser\GenericNameParser;
use Doctrine\DBAL\Schema\Name\Parser\OptionallyQualifiedNameParser;

/**
 * Representation of a Database View.
 *
 * @extends AbstractNamedObject<OptionallyQualifiedName>
 */
class View extends AbstractNamedObject
{
    public function __construct(string $name, private readonly string $sql)
    {
        parent::__construct($name);
    }

    protected function createNameParser(GenericNameParser $genericNameParser): OptionallyQualifiedNameParser
    {
        return new OptionallyQualifiedNameParser($genericNameParser);
    }

    public function getSql(): string
    {
        return $this->sql;
    }
}
