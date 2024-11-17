<?php

declare(strict_types=1);

namespace Doctrine\DBAL\Schema;

/**
 * Representation of a Database View.
 */
class View extends AbstractAsset
{
    public function __construct(string $name, private readonly string $sql)
    {
        parent::__construct($name);
    }

    public function getSql(): string
    {
        return $this->sql;
    }
}
