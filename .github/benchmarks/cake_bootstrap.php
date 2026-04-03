<?php
declare(strict_types=1);

use App\Application;
use Cake\Core\Configure;
use Cake\Http\MiddlewareQueue;

require dirname(__DIR__, 2) . '/vendor/autoload.php';
require dirname(__DIR__, 2) . '/config/bootstrap.php';

$iterations = isset($argv[1]) ? max(1, (int) $argv[1]) : 150;
$configDir = dirname(__DIR__, 2) . '/config';
$checksum = 0;

Configure::write('debug', false);

for ($i = 0; $i < $iterations; $i++) {
    $app = new Application($configDir);
    $app->bootstrap();

    $plugins = $app->getPlugins();
    $middleware = $app->middleware(new MiddlewareQueue());

    foreach ([0, 1, 2, 3, 4, 5] as $index) {
        $middleware->seek($index);
        $checksum += strlen($middleware->current()::class);
    }

    $checksum += $plugins->count();
}

echo $checksum, PHP_EOL;
