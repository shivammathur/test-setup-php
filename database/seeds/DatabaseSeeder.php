<?php

declare(strict_types=1);

use Phinx\Seed\AbstractSeed;

final class DatabaseSeeder extends AbstractSeed
{
    public function run(): void
    {
        $this->table('entries')
            ->insert([
                ['title' => 'Phalcon example'],
            ])
            ->saveData();
    }
}
