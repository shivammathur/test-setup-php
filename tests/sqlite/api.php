<?php
$t->test('api/sqlite3/connection-errors-reopen',function()use($t){
 $d=new Db($t,'sqlite3');$s=$d->db;
 $t->same(1,$t->call($s,'querySingle',['SELECT 1']));$t->same(['a'=>1,'b'=>'x'],$t->call($s,'querySingle',["SELECT 1 a,'x' b",true]));
 $t->same("O''Reilly",$t->call(SQLite3::class,'escapeString',["O'Reilly"]));
 $t->same(true,$t->call($s,'busyTimeout',[50]));
 $d->exec('CREATE TABLE unique_values(v UNIQUE); INSERT INTO unique_values VALUES(7)');
 $t->same(1,$t->call($s,'lastInsertRowID'));$t->same(1,$t->call($s,'changes'));
 $t->throws(fn()=>$d->exec('INSERT INTO unique_values VALUES(7)'),'/unique/i');
 $t->same(19,$t->call($s,'lastErrorCode')&255);$t->same(2067,$t->call($s,'lastExtendedErrorCode'));$t->ok(str_contains($t->call($s,'lastErrorMsg'),'UNIQUE'),'error message');
 $t->same(true,$t->call($s,'enableExtendedResultCodes',[true]));$t->throws(fn()=>$d->exec('INSERT INTO unique_values VALUES(7)'));$t->same(2067,$t->call($s,'lastExtendedErrorCode'));
 $t->call($s,'close');$t->throws(fn()=>$t->call($s,'querySingle',['SELECT 1']));
 $t->call($s,'open',[':memory:']);$t->same(9,$t->call($s,'querySingle',['SELECT 9']));$t->call($s,'close');
});
$t->test('api/sqlite3/statement-bind-reference-clear-reset-metadata',function()use($t){
 $d=new Db($t,'sqlite3');$d->exec('CREATE TABLE typed(i INTEGER,r REAL,t TEXT,b BLOB,n)');
 $s=$t->call($d->db,'prepare',['INSERT INTO typed VALUES(:i,:r,:t,:b,:n)']);$t->same(5,$t->call($s,'paramCount'));$t->same(false,$t->call($s,'readOnly'));
 $i=3;$t->call($s,'bindParam',[':i',&$i,SQLITE3_INTEGER]);$i=4;
 foreach([':r'=>[1.5,SQLITE3_FLOAT],':t'=>['é🙂',SQLITE3_TEXT],':b'=>["\x00\xff",SQLITE3_BLOB],':n'=>[null,SQLITE3_NULL]] as $name=>[$v,$type])$t->same(true,$t->call($s,'bindValue',[$name,$v,$type]));
 $t->ok(str_contains($t->call($s,'getSQL'),':i'),'original SQL');$t->ok(str_contains($t->call($s,'getSQL',[true]),'4'),'expanded reference');
 $r=$t->call($s,'execute');$t->call($r,'finalize');$t->call($s,'reset');$t->call($s,'clear');$t->call($s,'close');
 $q=$t->call($d->db,'prepare',['SELECT i,r,t,b,n FROM typed']);$t->same(true,$t->call($q,'readOnly'));$r=$t->call($q,'execute');
 $t->same(5,$t->call($r,'numColumns'));$t->same('i',$t->call($r,'columnName',[0]));
 $row=$t->call($r,'fetchArray',[SQLITE3_NUM]);$t->same([4,1.5,'é🙂',"\x00\xff",null],$row);
 foreach([SQLITE3_INTEGER,SQLITE3_FLOAT,SQLITE3_TEXT,SQLITE3_BLOB,SQLITE3_NULL] as $index=>$type)$t->same($type,$t->call($r,'columnType',[$index]));
 $t->same(false,$t->call($r,'fetchArray'));$t->call($r,'reset');$t->same(4,$t->call($r,'fetchArray',[SQLITE3_BOTH])['i']);
 if(PHP_VERSION_ID>=80500){$t->call($r,'reset');$t->same(1,count($t->call($r,'fetchAll',[SQLITE3_ASSOC])));}
 $t->call($r,'finalize');$t->call($q,'close');$t->throws(fn()=>$t->call($q,'execute'));
});
if(PHP_VERSION_ID>=80500)$t->test('api/sqlite3/statement-busy-explain',function()use($t){
 $s=$t->call((new Db($t,'sqlite3'))->db,'prepare',['SELECT 1 UNION ALL SELECT 2']);$t->same(false,$t->call($s,'busy'));$t->same(0,$t->call($s,'explain'));
 $t->same(true,$t->call($s,'setExplain',[2]));$t->same(2,$t->call($s,'explain'));$r=$t->call($s,'execute');$t->ok($t->call($r,'numColumns')>=4,'query-plan result');$t->call($r,'finalize');
 $t->call($s,'setExplain',[0]);$r=$t->call($s,'execute');$t->call($r,'fetchArray');$t->same(true,$t->call($s,'busy'));while($t->call($r,'fetchArray')!==false){}$t->same(false,$t->call($s,'busy'));$t->call($r,'finalize');$t->call($s,'close');
});
perDriver($t,'api/callbacks-scalar-aggregate-collation',function(Db $d)use($t){
 $native=$d->db instanceof SQLite3;$modern=$d->driver==='pdo-class';
 $methods=($native||$modern)?['createFunction','createAggregate','createCollation']:['sqliteCreateFunction','sqliteCreateAggregate','sqliteCreateCollation'];
 $invoke=function(string $method,array $args)use($t,$d){if(str_starts_with($method,'sqliteCreate')){$t->touch('PDO::'.$method);return expectedDeprecation($t,fn()=>$d->db->$method(...$args));}return $t->call($d->db,$method,$args);};
 $t->same(true,$invoke($methods[0],['qa_double',fn($v)=>$v===null?null:$v*2,1,SQLITE3_DETERMINISTIC]));
 $t->same(14,$d->one('SELECT qa_double(7)'));$t->same(null,$d->one('SELECT qa_double(NULL)'));
 $t->same(true,$invoke($methods[0],['qa_join',fn(...$a)=>implode('|',$a),-1]));$t->same('a|é|c',$d->one("SELECT qa_join('a','é','c')"));
 $t->same(true,$invoke($methods[1],['qa_sum',fn($ctx,$row,$v)=>($ctx??0)+$v,fn($ctx,$row)=>$ctx??0,1]));
 $t->same(6,$d->one('WITH a(v) AS(VALUES(1),(2),(3)) SELECT qa_sum(v) FROM a'));$t->same(0,$d->one('SELECT qa_sum(v) FROM (SELECT 1 v WHERE 0)'));
 $t->same(true,$invoke($methods[2],['qa_reverse',fn($a,$b)=>strcmp($b,$a)]));$t->same(['c','b','a'],$d->column("WITH a(v) AS(VALUES('a'),('c'),('b')) SELECT v FROM a ORDER BY v COLLATE qa_reverse"));
 $invoke($methods[0],['qa_throw',function(){throw new RuntimeException('callback failure');},0]);$t->throws(fn()=>$d->one('SELECT qa_throw()'),'/callback failure/');
 $d->exec('CREATE TABLE deterministic(x); CREATE INDEX deterministic_index ON deterministic(qa_double(x))');
});
foreach(drivers() as $driver)if($driver==='sqlite3'||($driver==='pdo-class'&&PHP_VERSION_ID>=80500))$t->test($driver.'/api/authorizer-deny-ignore-reset',function()use($t,$driver){
 $d=new Db($t,$driver);$d->exec("CREATE TABLE secret(id INTEGER,value TEXT); INSERT INTO secret VALUES(1,'hidden')");$seen=[];
 $t->call($d->db,'setAuthorizer',[function($action,$a,$b,$db,$source)use(&$seen){$seen[]=$action;if($action===SQLite3::DELETE)return SQLite3::DENY;if($action===SQLite3::READ&&$b==='value')return SQLite3::IGNORE;return SQLite3::OK;}]);
 $t->same(null,$d->one('SELECT value FROM secret'));$t->throws(fn()=>$d->exec('DELETE FROM secret'),'/authoriz/i');$t->ok(in_array(SQLite3::READ,$seen,true),'reads authorized');$t->ok(in_array(SQLite3::DELETE,$seen,true),'deletes authorized');
 $t->call($d->db,'setAuthorizer',[null]);$t->same('hidden',$d->one('SELECT value FROM secret'));
});
foreach(drivers() as $driver)if($driver!=='pdo')$t->test($driver.'/api/blob-streams',function()use($t,$driver){
 $d=new Db($t,$driver);$d->exec('CREATE TABLE data(id INTEGER PRIMARY KEY,b BLOB); INSERT INTO data VALUES(1,zeroblob(16))');
 $stream=$t->call($d->db,'openBlob',['data','b',1,'main',SQLITE3_OPEN_READWRITE]);$t->ok(is_resource($stream),'BLOB stream opened');
 $t->same(3,fwrite($stream,"A\0B"));$t->same(3,ftell($stream));$t->same(0,fseek($stream,0));$t->same("A\0B",fread($stream,3));$t->same(16,fstat($stream)['size']);fclose($stream);
 $read=$t->call($d->db,'openBlob',['data','b',1]);$t->same("A\0B".str_repeat("\0",13),stream_get_contents($read));fclose($read);
 $t->same('410042',$d->one('SELECT hex(substr(b,1,3)) FROM data'));$t->throws(fn()=>$t->call($d->db,'openBlob',['data','b',999]));
});
$t->test('api/sqlite3/backup-database-and-attachment',function()use($t){
 $a=new Db($t,'sqlite3');$a->exec("CREATE TABLE t(x);INSERT INTO t VALUES('snapshot')");$b=new Db($t,'sqlite3');$t->same(true,$t->call($a->db,'backup',[$b->db]));$t->same('snapshot',$b->one('SELECT x FROM t'));
 $a->exec("UPDATE t SET x='new'");$t->same('snapshot',$b->one('SELECT x FROM t'));$t->same('ok',$b->one('PRAGMA integrity_check'));
 $a->exec("ATTACH ':memory:' AS aux; CREATE TABLE aux.other(x); INSERT INTO aux.other VALUES(7)");$c=new Db($t,'sqlite3');$t->same(true,$t->call($a->db,'backup',[$c->db,'aux','main']));$t->same(7,$c->one('SELECT x FROM other'));
});
foreach(['pdo',...(class_exists('Pdo\\Sqlite')?['pdo-class']:[])] as $driver){
$t->test($driver.'/api/connection-attributes-transactions-errors',function()use($t,$driver){
 $d=new Db($t,$driver);$p=$d->db;$t->ok(in_array('sqlite',$t->call(PDO::class,'getAvailableDrivers'),true),'sqlite driver');
 foreach([PDO::ATTR_DRIVER_NAME=>'sqlite',PDO::ATTR_SERVER_VERSION=>'3.54.1',PDO::ATTR_CLIENT_VERSION=>'3.54.1',PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION] as $attr=>$expected)$t->same($expected,$t->call($p,'getAttribute',[$attr]));
 $t->same(true,$t->call($p,'setAttribute',[PDO::ATTR_TIMEOUT,1]));$t->same(true,$t->call($p,'setAttribute',[PDO::ATTR_DEFAULT_FETCH_MODE,PDO::FETCH_ASSOC]));
 $t->same("'O''Reilly'",$t->call($p,'quote',["O'Reilly"]));$d->exec('CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT)');
 $t->same(false,$t->call($p,'inTransaction'));$t->same(true,$t->call($p,'beginTransaction'));$t->same(true,$t->call($p,'inTransaction'));$d->exec("INSERT INTO t(v) VALUES('first')");$t->same('1',$t->call($p,'lastInsertId'));$t->call($p,'rollBack');$t->same(0,$d->one('SELECT count(*) FROM t'));
 $t->call($p,'beginTransaction');$d->exec("INSERT INTO t(v) VALUES('saved')");$t->call($p,'commit');$t->same(1,$d->one('SELECT count(*) FROM t'));$t->throws(fn()=>$t->call($p,'commit'));
 $t->call($p,'setAttribute',[PDO::ATTR_ERRMODE,PDO::ERRMODE_SILENT]);$t->same(false,$t->call($p,'exec',['INSERT INTO absent VALUES(1)']));$t->same('HY000',$t->call($p,'errorCode'));$info=$t->call($p,'errorInfo');$t->same(1,$info[1]);$t->ok(str_contains($info[2],'absent'),'driver error');$t->call($p,'setAttribute',[PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION]);
 $t->throws(fn()=>$t->call($p,'getAttribute',[999999]));
 if(PHP_VERSION_ID>=80400){$q=$t->call(PDO::class,'connect',['sqlite::memory:']);$t->ok($q instanceof Pdo\Sqlite,'PDO::connect driver subclass');}
});
$t->test($driver.'/api/statements-binding-metadata-errors',function()use($t,$driver){
 $d=new Db($t,$driver);$d->exec('CREATE TABLE typed(id INTEGER PRIMARY KEY,i INTEGER,t TEXT,b BLOB)');$s=$t->call($d->db,'prepare',['INSERT INTO typed(i,t,b) VALUES(:i,:t,:b)']);
 $i=5;$t->call($s,'bindParam',[':i',&$i,PDO::PARAM_INT]);$i=6;$t->call($s,'bindValue',[':t','é🙂',PDO::PARAM_STR]);$blob=fopen('php://memory','r+');fwrite($blob,"A\0B");rewind($blob);$t->call($s,'bindValue',[':b',$blob,PDO::PARAM_LOB]);$t->same(true,$t->call($s,'execute'));fclose($blob);$t->same(1,$t->call($s,'rowCount'));
 $q=$t->call($d->db,'query',['SELECT id,i,t,b FROM typed']);$t->same(4,$t->call($q,'columnCount'));$meta=$t->call($q,'getColumnMeta',[1]);$t->same('i',$meta['name']);$t->same('integer',$meta['native_type']);
 $t->same(true,$t->call($q,'getAttribute',[pdoConstant('ATTR_READONLY_STATEMENT')]));$t->same(false,$t->call($s,'getAttribute',[pdoConstant('ATTR_READONLY_STATEMENT')]));
 $v=null;$t->call($q,'bindColumn',['i',&$v,PDO::PARAM_INT]);$t->same(true,$t->call($q,'fetch',[PDO::FETCH_BOUND]));$t->same(6,$v);$t->call($q,'closeCursor');
 ob_start();$t->call($s,'debugDumpParams');$dump=ob_get_clean();$t->ok(str_contains($dump,'Params:  3'),'debug parameter count');
 $t->same('00000',$t->call($s,'errorCode'));$t->same('00000',$t->call($s,'errorInfo')[0]);$t->throws(fn()=>$t->call($s,'nextRowset'));if(PHP_VERSION_ID>=80500)$t->same(false,$t->call($s,'setAttribute',[999999,1]));else $t->throws(fn()=>$t->call($s,'setAttribute',[999999,1]),'/support/i',PDOException::class);
 $t->throws(fn()=>$d->rows('SELECT ?',[1,2]));
 if(PHP_VERSION_ID>=80500){$q=$t->call($d->db,'prepare',['SELECT 1 UNION ALL SELECT 2']);$t->same(false,$t->call($q,'getAttribute',[Pdo\Sqlite::ATTR_BUSY_STATEMENT]));$t->same(0,$t->call($q,'getAttribute',[Pdo\Sqlite::ATTR_EXPLAIN_STATEMENT]));$t->call($q,'setAttribute',[Pdo\Sqlite::ATTR_EXPLAIN_STATEMENT,2]);$t->call($q,'execute');$t->ok(count($t->call($q,'fetchAll'))>0,'PDO explain mode');$t->call($q,'closeCursor');}
});
$t->test($driver.'/api/all-fetch-modes',function()use($t,$driver){
 $d=new Db($t,$driver);$p=$d->db;$sql="SELECT 1 id,'alpha' name UNION ALL SELECT 2,'beta'";
 $query=fn()=>$t->call($p,'query',[$sql]);
 $t->same([1,'alpha'],$t->call($query(),'fetch',[PDO::FETCH_NUM]));$t->same(['id'=>1,'name'=>'alpha'],$t->call($query(),'fetch',[PDO::FETCH_ASSOC]));
 $both=$t->call($query(),'fetch',[PDO::FETCH_BOTH]);$t->same(1,$both[0]);$t->same('alpha',$both['name']);
 $t->same('alpha',$t->call($query(),'fetch',[PDO::FETCH_OBJ])->name);$lazy=$t->call($query(),'fetch',[PDO::FETCH_LAZY]);$t->same(1,$lazy->id);$t->ok($lazy instanceof PDORow,'lazy row class');
 $t->same('alpha',$t->call($query(),'fetchObject')->name);$t->same(1,$t->call($query(),'fetchColumn',[0]));$t->same([1,2],$t->call($query(),'fetchAll',[PDO::FETCH_COLUMN,0]));
 $t->same([1=>'alpha',2=>'beta'],$t->call($query(),'fetchAll',[PDO::FETCH_KEY_PAIR]));
 $q=$query();$t->call($q,'setFetchMode',[PDO::FETCH_NUM]);$t->same([[1,'alpha'],[2,'beta']],iterator_to_array($t->call($q,'getIterator')));
 $q=$t->call($p,'query', ["SELECT 1 x,2 x"]);$t->same(['x'=>[1,2]],$t->call($q,'fetch',[PDO::FETCH_NAMED]));
 $objects=$t->call($query(),'fetchAll',[PDO::FETCH_CLASS,stdClass::class]);$t->same('beta',$objects[1]->name);
 $target=new stdClass();$q=$query();$t->call($q,'setFetchMode',[PDO::FETCH_INTO,$target]);$t->same($target,$t->call($q,'fetch'));$t->same('alpha',$target->name);
 $t->same(['1:alpha','2:beta'],$t->call($query(),'fetchAll',[PDO::FETCH_FUNC,fn($id,$name)=>"$id:$name"]));
 $group=$t->call($t->call($p,'query',["SELECT 'g' k,1 v UNION ALL SELECT 'g',2"]),'fetchAll',[PDO::FETCH_GROUP|PDO::FETCH_COLUMN]);$t->same(['g'=>[1,2]],$group);
 $unique=$t->call($query(),'fetchAll',[PDO::FETCH_UNIQUE|PDO::FETCH_ASSOC]);$t->same(['name'=>'beta'],$unique[2]);
 $t->call($p,'setAttribute',[PDO::ATTR_STRINGIFY_FETCHES,true]);$t->same('1',$t->call($query(),'fetchColumn'));$t->call($p,'setAttribute',[PDO::ATTR_STRINGIFY_FETCHES,false]);
 $t->call($p,'setAttribute',[PDO::ATTR_CASE,PDO::CASE_UPPER]);$t->same(['ID'=>1,'NAME'=>'alpha'],$t->call($query(),'fetch',[PDO::FETCH_ASSOC]));
});
}
$t->test('api/sqlite3/direct-query',function()use($t){$s=(new Db($t,'sqlite3'))->db;$r=$t->call($s,'query',['SELECT 7 AS n']);$t->same(['n'=>7],$t->call($r,'fetchArray',[SQLITE3_ASSOC]));$t->call($r,'finalize');});
perDriver($t,'api/extension-loading',function(Db $d)use($t){
 $extension=getenv('SQLITE_QA_EXTENSION');$t->ok(is_string($extension)&&is_file($extension),'extension fixture must exist');
 $t->throws(fn()=>$d->one('SELECT load_extension(?)',[$extension]),'/authoriz/i');
 if($d->driver==='pdo')return;
 $t->throws(fn()=>$t->call($d->db,'loadExtension',['qa_missing_extension']),'/open|load|exist|find/i');
 $t->same($d->driver==='sqlite3'?true:null,$t->call($d->db,'loadExtension',[$d->driver==='sqlite3'?basename($extension):$extension]));
 $t->near(14,$d->one('SELECT qa_extension_double(7)'));
 if(PHP_OS_FAMILY==='Windows')$t->same(strtolower(realpath(getenv('SQLITE_QA_LIBRARY'))),strtolower(realpath($d->one('SELECT qa_library_path()'))),'actual loaded SQLite DLL');$t->same(null,$d->one('SELECT qa_extension_double(NULL)'));
 $t->throws(fn()=>$d->one('SELECT load_extension(?)',[$extension]),'/authoriz/i');
});
$t->test('api/sqlite3/rebinding-clearing-fetch-modes-invalid-arguments',function()use($t){
 $d=new Db($t,'sqlite3');$s=$t->call($d->db,'prepare',['SELECT :v AS v']);$t->call($s,'bindValue',[':v',7,SQLITE3_INTEGER]);$r=$t->call($s,'execute');$t->same([7],$t->call($r,'fetchArray',[SQLITE3_NUM]));$t->call($r,'finalize');$t->call($s,'clear');$r=$t->call($s,'execute');$t->same([null],$t->call($r,'fetchArray',[SQLITE3_NUM]));$t->call($r,'finalize');
 $t->call($s,'bindValue',[':v','new',SQLITE3_TEXT]);$r=$t->call($s,'execute');$t->same(['v'=>'new'],$t->call($r,'fetchArray',[SQLITE3_ASSOC]));$t->call($r,'finalize');$t->call($s,'close');
 $t->throws(fn()=>$t->call($d->db,'prepare',['SELECT FROM']));$t->same(1,$d->one('SELECT 1'));
 $t->throws(fn()=>serialize($d->db));$t->throws(fn()=>serialize($s));
 if(PHP_VERSION_ID>=80500){foreach([SQLITE3_NUM,SQLITE3_ASSOC,SQLITE3_BOTH] as $mode){$r=$t->call($d->db,'query',['SELECT 1 v UNION ALL SELECT 2']);$rows=$t->call($r,'fetchAll',[$mode]);$t->same(2,count($rows));$t->same(2,$rows[1][$mode===SQLITE3_NUM?0:'v']);$t->call($r,'finalize');}}
});
perDriver($t,'api/callback-replacement-and-connection-recovery',function(Db $d)use($t){
 $method=$d->driver==='pdo'?'sqliteCreateFunction':'createFunction';$register=function($callback)use($t,$d,$method){return $d->driver==='pdo'?expectedDeprecation($t,fn()=>$d->db->$method('qa_value',$callback,1)):$t->call($d->db,$method,['qa_value',$callback,1]);};
 $register(fn($x)=>$x);$t->same('é🙂',$d->one("SELECT qa_value('é🙂')"));$register(fn($x)=>null);$t->same(null,$d->one('SELECT qa_value(3)'));$register(fn($x)=>1.25);$t->near(1.25,$d->one('SELECT qa_value(3)'));
 $t->throws(fn()=>$d->one('SELECT qa_value()'));$t->same(2,$d->one('SELECT 1+1'));
});
