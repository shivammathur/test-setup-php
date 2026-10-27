<?php
declare(strict_types=1);
require __DIR__.'/harness.php';
$options=getopt('',['report:','work:']);
$GLOBALS['work']=$options['work']??sys_get_temp_dir().'/sqlite-userland-'.getmypid();
if(!is_dir($GLOBALS['work']))mkdir($GLOBALS['work'],0777,true);
set_error_handler(static function(int $severity,string $message,string $file,int $line): bool {if(!(error_reporting()&$severity))return false;throw new ErrorException($message,0,$severity,$file,$line);});
$t=new Suite();
foreach(['provenance','functions','json','features','sql','api','storage','pragmas'] as $module) require __DIR__.'/'.$module.'.php';
require __DIR__.'/coverage.php';
exit($t->report($options['report']??$GLOBALS['work'].'/reports'));
