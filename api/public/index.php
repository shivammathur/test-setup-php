<?php

use Niden\Bootstrap\Api;

require_once __DIR__ . '/../../library/Core/autoload.php';

$dotenv = Dotenv\Dotenv::create(__DIR__);
$dotenv->load();

$bootstrap = new Api();

$bootstrap->setup();
$bootstrap->run();
