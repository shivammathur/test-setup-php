<?php

declare(strict_types=1);

use Yiisoft\Db\Pgsql\Dsn;

return [
    'yiisoft/db-pgsql' => [
        'dsn' => new Dsn(
            'pgsql',
            getenv('DB_HOST') ?: '127.0.0.1',
            getenv('DB_NAME') ?: 'app',
            getenv('DB_PORT') ?: '5432',
        ),
        'username' => getenv('DB_USERNAME') ?: 'postgres',
        'password' => getenv('DB_PASSWORD') ?: 'postgres',
    ],
    'yiisoft/db-migration' => [
        'newMigrationNamespace' => 'App\\Migration',
        'sourceNamespaces' => ['App\\Migration'],
    ],
];
