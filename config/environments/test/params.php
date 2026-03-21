<?php

declare(strict_types=1);

use Yiisoft\Db\Mysql\Dsn;

return [
    'yiisoft/db-mysql' => [
        'dsn' => new Dsn(
            'mysql',
            getenv('DB_HOST') ?: '127.0.0.1',
            getenv('DB_NAME') ?: 'app',
            getenv('DB_PORT') ?: '3306',
        ),
        'username' => getenv('DB_USERNAME') ?: 'root',
        'password' => getenv('DB_PASSWORD') ?: 'password',
    ],
    'yiisoft/db-migration' => [
        'newMigrationNamespace' => 'App\\Migration',
        'sourceNamespaces' => ['App\\Migration'],
    ],
];
