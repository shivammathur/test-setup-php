<?php

declare(strict_types=1);

namespace Tests\Acceptance;

use Tests\Support\AcceptanceTester;

final class PhalconCest
{
    public function landingPageIsAvailable(AcceptanceTester $I): void
    {
        $I->amOnPage('/');
        $I->see('Phalcon PostgreSQL');
        $I->see('rows: 1');
    }
}
