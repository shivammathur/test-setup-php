<?php
// A separate PHP process holds a write transaction, then exits without committing.
require __DIR__.'/harness.php';
[$script,$driver,$path,$ready,$release]=$argv;
$d=new Db(new Suite(),$driver,$path);$d->exec('BEGIN IMMEDIATE; UPDATE t SET x=2');
file_put_contents($ready,'ready');$deadline=microtime(true)+20;
while(!is_file($release)&&microtime(true)<$deadline){usleep(10000);clearstatcache();}
exit(is_file($release)?0:2);
