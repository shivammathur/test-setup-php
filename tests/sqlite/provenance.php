<?php
perDriver($t,'provenance/version-source-options',function(Db $d)use($t){
 $t->same('3.54.1',$d->one('SELECT sqlite_version()'));
 $t->same('2026-10-16 14:45:20 555e07ef33f69a0957d24d8e555b702464a131d6f1607f4c3c1e4551e8e6ca76',$d->one('SELECT sqlite_source_id()'));
 foreach(['ENABLE_MATH_FUNCTIONS','ENABLE_PERCENTILE','ENABLE_RTREE','ENABLE_DBSTAT_VTAB','ENABLE_FTS3','ENABLE_FTS4','ENABLE_FTS5','ENABLE_COLUMN_METADATA','THREADSAFE'] as $flag)if(PHP_OS_FAMILY==='Windows'||$flag!=='ENABLE_FTS4')$t->same(1,$d->one('SELECT sqlite_compileoption_used(?)',[$flag]),$flag);
 $flags=$d->column('PRAGMA compile_options');$t->ok(count($flags)>10,'compile options populated');
 for($i=0;$i<count($flags);$i++)$t->same($flags[$i],$d->one('SELECT sqlite_compileoption_get(?)',[$i]));
 $t->same(null,$d->one('SELECT sqlite_compileoption_get(10000)'));
 $t->inventory[$d->driver]['functions']=$d->rows('PRAGMA function_list');
 $t->inventory[$d->driver]['modules']=$d->rows('PRAGMA module_list');
 $t->inventory[$d->driver]['pragmas']=$d->rows('PRAGMA pragma_list');
});
$t->test('sqlite3/version-api',function()use($t){$v=$t->call(SQLite3::class,'version');$t->same('3.54.1',$v['versionString']);$t->same(3054001,$v['versionNumber']);});
$t->test('provenance/runtime-configuration',function()use($t){
 $t->ok(extension_loaded('sqlite3'),'SQLite3 loaded');$t->ok(extension_loaded('pdo_sqlite'),'PDO SQLite loaded');
 if(PHP_OS_FAMILY==='Windows'){
  $t->ok(extension_loaded('Zend OPcache'),'OPcache loaded for both modes');$status=opcache_get_status(false);$enabled=ini_get('opcache.enable_cli')==='1';$t->same($enabled,is_array($status)&&$status['opcache_enabled']);
  $t->same(false,php_ini_scanned_files(),'isolated INI scan');
 }
});
