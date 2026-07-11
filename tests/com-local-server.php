<?php
foreach (['PHPTest.LocalByRefServer', 'InternetExplorer.Application'] as $progId) {
    $server = new com($progId);
    $x = 0;
    $y = 0;
    $server->clientToWindow($x, $y);
    if ($x !== 1024 || $y !== 768) {
        throw new RuntimeException("$progId returned x=$x, y=$y");
    }
    $server->quit();
    echo "$progId: x=$x, y=$y\n";
}
