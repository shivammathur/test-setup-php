<?php
perDriver($t,'storage/persistence-cross-api-readonly-large-blob',function(Db $unused,string $driver)use($t){
 $path=pathFor($driver.'-persistent');$d=new Db($t,$driver,$path);$d->exec('CREATE TABLE records(id INTEGER PRIMARY KEY,t TEXT,b BLOB)');
 $blob=str_repeat("A\0\xffé",220000);$d->rows('INSERT INTO records VALUES(1,?,CAST(? AS BLOB))',['路径 é🙂',$blob]);
 $t->same(strlen($blob),$d->one('SELECT length(b) FROM records'));unset($d);
 foreach(drivers() as $reader){$r=new Db($t,$reader,$path);$row=$r->rows('SELECT t,b FROM records')[0];$t->same('路径 é🙂',$row['t']);$t->same(hash('sha256',$blob),hash('sha256',$row['b']));unset($r);}
 $options=$driver==='sqlite3'?['flags'=>SQLITE3_OPEN_READONLY]:[pdoConstant('ATTR_OPEN_FLAGS')=>pdoConstant('OPEN_READONLY')];
 $r=new Db($t,$driver,$path,$options);$t->same(1,$r->one('SELECT count(*) FROM records'));$t->throws(fn()=>$r->exec('DELETE FROM records'),'/readonly|read.only/i');
 $t->same('9223372036854775807',$r->one('SELECT CAST(9223372036854775807 AS TEXT)'));$t->same('-9223372036854775808',$r->one('SELECT CAST(-9223372036854775808 AS TEXT)'));
});
foreach(['delete','truncate','persist','memory','off','wal'] as $mode)perDriver($t,'storage/journal-'.$mode,function(Db $unused,string $driver)use($t,$mode){
 $d=new Db($t,$driver,pathFor($driver.'-journal-'.$mode));$t->same($driver==='sqlite3'&&$mode==='off'?'delete':$mode,$d->one('PRAGMA journal_mode='.$mode));
 $d->exec('CREATE TABLE t(x); BEGIN; INSERT INTO t VALUES(1); COMMIT');$t->same(1,$d->one('SELECT x FROM t'));
 if($mode!=='off'){$d->exec('BEGIN; INSERT INTO t VALUES(2); ROLLBACK');$t->same(1,$d->one('SELECT count(*) FROM t'));}
 $t->same('ok',$d->one('PRAGMA integrity_check'));$t->same('ok',$d->one('PRAGMA quick_check'));
 if($mode==='wal'){$checkpoint=$d->rows('PRAGMA wal_checkpoint(TRUNCATE)')[0];$t->same(0,$checkpoint['busy']);}
});
perDriver($t,'storage/wal-snapshot-busy-recovery',function(Db $unused,string $driver)use($t){
 $path=pathFor($driver.'-snapshot');$a=new Db($t,$driver,$path);$a->one('PRAGMA journal_mode=WAL');$a->exec('CREATE TABLE t(x); INSERT INTO t VALUES(1)');$b=new Db($t,$driver,$path);
 $a->exec('PRAGMA busy_timeout=10; BEGIN');$t->same(1,$a->one('SELECT x FROM t'));$b->exec('UPDATE t SET x=2');$t->same(1,$a->one('SELECT x FROM t'));$a->exec('COMMIT');$t->same(2,$a->one('SELECT x FROM t'));
 $a->exec('BEGIN IMMEDIATE');$b->exec('PRAGMA busy_timeout=10');$t->throws(fn()=>$b->exec('UPDATE t SET x=3'),'/locked|busy/i');$a->exec('ROLLBACK');$b->exec('UPDATE t SET x=3');$t->same(3,$a->one('SELECT x FROM t'));
});
perDriver($t,'storage/attach-vacuum-pragmas-schema',function(Db $d,string $driver)use($t){
 $d->exec('PRAGMA foreign_keys=ON; PRAGMA recursive_triggers=ON; PRAGMA busy_timeout=37; PRAGMA cache_size=-2000; PRAGMA temp_store=MEMORY; PRAGMA read_uncommitted=OFF; PRAGMA trusted_schema=OFF; PRAGMA secure_delete=ON');
 foreach(['foreign_keys'=>1,'recursive_triggers'=>1,'busy_timeout'=>37,'cache_size'=>-2000,'temp_store'=>2,'read_uncommitted'=>0,'trusted_schema'=>0,'secure_delete'=>1] as $pragma=>$expected)$t->same($expected,$d->one('PRAGMA '.$pragma));
 $aux=pathFor($driver.'-aux');$d->rows('ATTACH DATABASE ? AS aux',[$aux]);$d->exec('CREATE TABLE aux.t(id INTEGER PRIMARY KEY,v TEXT); INSERT INTO aux.t VALUES(1,\'attached\')');
 $t->same('attached',$d->one('SELECT v FROM aux.t'));$t->same(2,count($d->rows('PRAGMA database_list')));$d->exec('PRAGMA aux.application_id=1234; PRAGMA aux.user_version=7');$t->same(1234,$d->one('PRAGMA aux.application_id'));$t->same(7,$d->one('PRAGMA aux.user_version'));
 $t->ok(count($d->rows("SELECT * FROM dbstat('aux')"))>0,'attached DBSTAT');$d->exec('DETACH aux');
 $file=new Db($t,$driver,$aux);$t->same(7,$file->one('PRAGMA user_version'));$copy=pathFor($driver.'-vacuum');$file->rows('VACUUM INTO ?',[$copy]);$c=new Db($t,$driver,$copy);$t->same('attached',$c->one('SELECT v FROM t'));$t->same('ok',$c->one('PRAGMA integrity_check'));
 $file->exec('PRAGMA query_only=ON');$t->throws(fn()=>$file->exec('DELETE FROM t'));$file->exec('PRAGMA query_only=OFF');$file->exec('DELETE FROM t; VACUUM');$t->same(0,$file->one('PRAGMA freelist_count'));
});
perDriver($t,'storage/child-process-lock-and-uncommitted-exit',function(Db $unused,string $driver)use($t){
 $path=pathFor($driver.'-child');$d=new Db($t,$driver,$path);$d->exec('CREATE TABLE t(x); INSERT INTO t VALUES(1); PRAGMA busy_timeout=10');
 $ready=$path.'.ready';$release=$path.'.release';$ini=php_ini_loaded_file();$cmd=[PHP_BINARY,...($ini?['-c',$ini]:['-n']),__DIR__.'/worker.php',$driver,$path,$ready,$release];
 $pipes=[];$log=$path.'.log';$proc=proc_open($cmd,[0=>['pipe','r'],1=>['file',$log,'w'],2=>['file',$log,'a']],$pipes);$t->ok(is_resource($proc),'worker starts');fclose($pipes[0]);
 try{$deadline=microtime(true)+15;while(!is_file($ready)&&microtime(true)<$deadline){$status=proc_get_status($proc);if(!$status['running'])break;usleep(10000);clearstatcache();}
  $t->ok(is_file($ready),'worker acquired lock: '.file_get_contents($log));$t->same(1,$d->one('SELECT x FROM t'));$t->throws(fn()=>$d->exec('UPDATE t SET x=3'),'/locked|busy/i');file_put_contents($release,'release');
  $deadline=microtime(true)+15;do{$status=proc_get_status($proc);if(!$status['running'])break;usleep(10000);}while(microtime(true)<$deadline);$t->same(false,$status['running'],'worker exits');$t->same(0,$status['exitcode'],'worker exit');
  $t->same(1,$d->one('SELECT x FROM t'));$d->exec('UPDATE t SET x=4');$t->same(4,$d->one('SELECT x FROM t'));$t->same('ok',$d->one('PRAGMA integrity_check'));
 }finally{file_put_contents($release,'release');if(proc_get_status($proc)['running'])proc_terminate($proc);proc_close($proc);}
});
foreach(['pdo',...(class_exists('Pdo\\Sqlite')?['pdo-class']:[])] as $driver){
 $t->test($driver.'/api/extended-errors-and-open-flags',function()use($t,$driver){$d=new Db($t,$driver,':memory:',[pdoConstant('ATTR_EXTENDED_RESULT_CODES')=>true]);$d->exec('CREATE TABLE t(x UNIQUE); INSERT INTO t VALUES(1)');$e=$t->throws(fn()=>$d->exec('INSERT INTO t VALUES(1)'),'',PDOException::class);$t->same(2067,$e->errorInfo[1]);});
 if(PHP_VERSION_ID>=80500)$t->test($driver.'/api/transaction-modes',function()use($t,$driver){foreach([0,1,2] as $mode){$path=pathFor($driver.'-mode-'.$mode);$d=new Db($t,$driver,$path);$d->exec('CREATE TABLE t(x)');$other=new Db($t,$driver,$path);$other->exec('PRAGMA busy_timeout=10');$t->call($d->db,'setAttribute',[Pdo\Sqlite::ATTR_TRANSACTION_MODE,$mode]);$t->same($mode,$t->call($d->db,'getAttribute',[Pdo\Sqlite::ATTR_TRANSACTION_MODE]));$t->call($d->db,'beginTransaction');if($mode===0)$other->exec('INSERT INTO t VALUES(1)');else $t->throws(fn()=>$other->exec('INSERT INTO t VALUES(1)'),'/locked|busy/i');$t->call($d->db,'rollBack');}});
}
