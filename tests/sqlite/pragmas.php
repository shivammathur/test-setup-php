<?php
perDriver($t,'pragma/connection-settings-and-behaviour',function(Db $d)use($t){
 foreach(['automatic_index'=>0,'cache_spill'=>0,'cell_size_check'=>1,'checkpoint_fullfsync'=>1,'fullfsync'=>1,'ignore_check_constraints'=>1,'legacy_alter_table'=>1,'reverse_unordered_selects'=>1,'synchronous'=>1,'threads'=>2,'wal_autocheckpoint'=>17,'analysis_limit'=>100,'journal_size_limit'=>8192] as $name=>$value){$d->exec("PRAGMA $name=$value");$t->same($value,$d->one('PRAGMA '.$name),$name);}
 $d->exec('CREATE TABLE checked(v CHECK(v>0)); INSERT INTO checked VALUES(-1)');$t->same(-1,$d->one('SELECT v FROM checked'));$d->exec('PRAGMA ignore_check_constraints=OFF');$t->throws(fn()=>$d->exec('INSERT INTO checked VALUES(-2)'));
 $d->exec('CREATE TABLE ordered(v); INSERT INTO ordered VALUES(1),(2),(3)');$t->same([3,2,1],$d->column('SELECT v FROM ordered'));$d->exec('PRAGMA reverse_unordered_selects=OFF');$t->same([1,2,3],$d->column('SELECT v FROM ordered'));
 $d->exec('PRAGMA case_sensitive_like=ON');$t->same(0,$d->one("SELECT 'A' LIKE 'a'"));$d->exec('PRAGMA case_sensitive_like=OFF');$t->same(1,$d->one("SELECT 'A' LIKE 'a'"));
 $d->exec('PRAGMA foreign_keys=ON; CREATE TABLE p(id PRIMARY KEY); CREATE TABLE c(pid REFERENCES p(id)); BEGIN; PRAGMA defer_foreign_keys=ON; INSERT INTO c VALUES(1); INSERT INTO p VALUES(1); COMMIT');$t->same([],$d->rows('PRAGMA foreign_key_check'));$t->same(0,$d->one('PRAGMA defer_foreign_keys'));
 $d->exec('PRAGMA short_column_names=OFF; PRAGMA full_column_names=ON');$t->same(['ordered.v'=>1],$d->rows('SELECT v FROM ordered LIMIT 1')[0]);
 $d->exec('PRAGMA count_changes=ON');$t->same(1,$d->driver==='sqlite3'?$t->call($d->db,'querySingle',['UPDATE ordered SET v=7 WHERE v=1']):$d->one('UPDATE ordered SET v=7 WHERE v=1'));$d->exec('PRAGMA count_changes=OFF');
 $t->ok(count($d->rows('PRAGMA collation_list'))>=3,'built-in collations');$t->ok(count($d->rows('PRAGMA table_list'))>=5,'table list');$d->exec('CREATE INDEX ordered_index ON ordered(v)');$t->same('v',$d->rows('PRAGMA index_info(ordered_index)')[0]['name']);
 $t->same(0,$d->one('PRAGMA writable_schema'));$t->ok($d->one('PRAGMA schema_version')>0,'schema version advances');
 // Process-wide limits are read only here; lowering the hard limit would affect later tests.
 foreach(['hard_heap_limit','soft_heap_limit'] as $name)$t->ok($d->one('PRAGMA '.$name)>=0,'memory-limit introspection');
 $d->exec('PRAGMA shrink_memory');$t->same(3,$d->one('SELECT count(*) FROM ordered'));
});
perDriver($t,'pragma/file-header-vacuum-data-version',function(Db $unused,string $driver)use($t){
 $path=pathFor($driver.'-pragmas');$d=new Db($t,$driver,$path);$d->exec("PRAGMA page_size=1024; PRAGMA auto_vacuum=INCREMENTAL; PRAGMA encoding='UTF-16le'; CREATE TABLE t(v BLOB); INSERT INTO t VALUES(zeroblob(40000))");
 $t->same(1024,$d->one('PRAGMA page_size'));$t->same(2,$d->one('PRAGMA auto_vacuum'));$t->same('UTF-16le',$d->one('PRAGMA encoding'));$t->ok($d->one('PRAGMA page_count')>30,'multiple pages');
 $d->exec('DELETE FROM t');$free=$d->one('PRAGMA freelist_count');$t->ok($free>0,'freed pages');$d->exec('PRAGMA incremental_vacuum');$t->same(0,$d->one('PRAGMA freelist_count'));
 $t->same(1000,$d->one('PRAGMA max_page_count=1000'));$t->ok($d->one('PRAGMA mmap_size=1048576')>=0,'mapping setting');$t->same('normal',$d->one('PRAGMA locking_mode'));$t->same('exclusive',$d->one('PRAGMA locking_mode=EXCLUSIVE'));$t->same('normal',$d->one('PRAGMA locking_mode=NORMAL'));
 $before=$d->one('PRAGMA data_version');$other=new Db($t,$driver,$path);$other->exec("INSERT INTO t VALUES('external')");$t->ok($d->one('PRAGMA data_version')>$before,'other connection increments data version');
 $d->exec('PRAGMA default_cache_size=200');$t->same(200,$d->one('PRAGMA default_cache_size'));$d->exec('PRAGMA empty_result_callbacks=ON');$t->same(1,$d->one('PRAGMA empty_result_callbacks'));
});
