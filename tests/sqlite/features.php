<?php
foreach(['fts3','fts4','fts5'] as $module)perDriver($t,'fts/'.$module.'/search-update-delete-rebuild',function(Db $d)use($t,$module){
 $d->exec("CREATE VIRTUAL TABLE docs USING $module(title,body)");
 $d->exec("INSERT INTO docs(rowid,title,body) VALUES(1,'red fox','quick brown fox'),(2,'blue bird','slow blue bird'),(3,'fox news','a quick fox jumps')");
 $t->same([1,3],$d->column("SELECT rowid FROM docs WHERE docs MATCH 'quick' ORDER BY rowid"));
 $t->same([1],$d->column("SELECT rowid FROM docs WHERE docs MATCH '\"brown fox\"'"));
 $t->same([1,3],$d->column("SELECT rowid FROM docs WHERE docs MATCH 'qui*' ORDER BY rowid"));
 $t->same([2],$d->column("SELECT rowid FROM docs WHERE docs MATCH 'title:blue'"));
 $t->same([1,2,3],$d->column("SELECT rowid FROM docs WHERE docs MATCH 'quick OR bird' ORDER BY rowid"));
 if($module==='fts5'){
  $t->same('red [fox]',$d->one("SELECT highlight(docs,0,'[',']') FROM docs WHERE docs MATCH 'fox' AND rowid=1"));
  $t->ok(str_contains($d->one("SELECT snippet(docs,1,'[',']','...',8) FROM docs WHERE docs MATCH 'fox' AND rowid=1"),'[fox]'),'snippet marks match');
  $t->ok(is_numeric($d->one("SELECT bm25(docs) FROM docs WHERE docs MATCH 'fox' LIMIT 1")),'bm25 score');
  $d->exec('CREATE VIRTUAL TABLE vocab USING fts5vocab(docs,row)');$t->same(2,$d->one("SELECT doc FROM vocab WHERE term='quick'"));
  $t->ok(str_contains($d->one('SELECT fts5_source_id()'),' '),'FTS5 source identifier');
  $t->same(null,$d->one('SELECT fts5(NULL)'));
  $t->same([1,3],$d->column("SELECT rowid FROM docs WHERE docs MATCH fts5_insttoken('quick') ORDER BY rowid"));
  $d->exec("INSERT INTO docs(docs) VALUES('integrity-check')");
 }else{
  $t->ok(str_contains($d->one("SELECT snippet(docs,'[',']','...',-1,8) FROM docs WHERE docs MATCH 'fox' AND rowid=1"),'[fox]'),'legacy snippet');
  $t->ok(strlen($d->one("SELECT matchinfo(docs,'pcx') FROM docs WHERE docs MATCH 'fox' LIMIT 1"))>=12,'matchinfo blob');
  $t->ok(strlen($d->one("SELECT offsets(docs) FROM docs WHERE docs MATCH 'fox' LIMIT 1"))>0,'token offsets');
  $t->same([1,3],$d->column("SELECT rowid FROM docs WHERE match('fox',docs) ORDER BY rowid"));
  $d->one("SELECT optimize(docs) FROM docs LIMIT 1");$t->same('Index already optimal',$d->one("SELECT optimize(docs) FROM docs LIMIT 1"));
 }
 $d->exec("UPDATE docs SET body='a turtle' WHERE rowid=3");$t->same([1],$d->column("SELECT rowid FROM docs WHERE docs MATCH 'quick'"));
 $d->exec('DELETE FROM docs WHERE rowid=1');$t->same(0,$d->one("SELECT count(*) FROM docs WHERE docs MATCH 'quick'"));
 $d->exec("INSERT INTO docs(docs) VALUES('rebuild'); INSERT INTO docs(docs) VALUES('optimize')");
 $t->same(2,$d->one('SELECT count(*) FROM docs'));$t->throws(fn()=>$d->rows("SELECT * FROM docs WHERE docs MATCH '\"unterminated'"));
});
perDriver($t,'fts/tokenizers-external-content-locale',function(Db $d)use($t){
 $d->exec("CREATE VIRTUAL TABLE tokenizer USING fts3tokenize(unicode61)");
 $t->same(['cafe','fox'],$d->column("SELECT token FROM tokenizer WHERE input='Café FOX' ORDER BY position"));
 $t->same(null,$d->one("SELECT fts3_tokenizer('simple')"));$t->ok(in_array($d->one("SELECT length(fts3_tokenizer(?))",["simple"]),[4,8],true),"bound tokenizer lookup");
 $d->exec('CREATE TABLE source(id INTEGER PRIMARY KEY,body TEXT)');
 $d->exec("CREATE VIRTUAL TABLE search USING fts5(body,content=source,content_rowid=id,tokenize='porter unicode61')");
 $d->exec("INSERT INTO source VALUES(1,'running runner'); INSERT INTO search(search) VALUES('rebuild')");
 $t->same(1,$d->one("SELECT rowid FROM search WHERE search MATCH 'run'"));
 $d->exec("CREATE VIRTUAL TABLE localized USING fts5(text,locale=1)");
 $d->exec("INSERT INTO localized VALUES(fts5_locale('en_US','hello world'))");
 $t->same('en_US',$d->one("SELECT fts5_get_locale(localized,0) FROM localized WHERE localized MATCH 'hello'"));
 $d->exec("CREATE VIRTUAL TABLE tri USING fts5(text,tokenize='trigram'); INSERT INTO tri VALUES('abcdefgh')");
 $t->same('abcdefgh',$d->one("SELECT text FROM tri WHERE tri MATCH 'cde'"));
});
foreach(['rtree','rtree_i32'] as $module)perDriver($t,'spatial/'.$module,function(Db $d)use($t,$module){
 $d->exec("CREATE VIRTUAL TABLE boxes USING $module(id,x1,x2,y1,y2,+label)");
 $d->exec("INSERT INTO boxes VALUES(1,0,10,0,10,'a'),(2,20,30,20,30,'b'),(3,5,15,5,15,'c')");
 $t->same([1,3],$d->column('SELECT id FROM boxes WHERE x1<=8 AND x2>=8 AND y1<=8 AND y2>=8 ORDER BY id'));
 $t->same('ok',$d->one("SELECT rtreecheck('boxes')"));$t->same('ok',$d->one("SELECT rtreecheck('main','boxes')"));
 $t->same(0,$d->one('SELECT rtreedepth(data) FROM boxes_node WHERE nodeno=1'));
 $t->ok(str_contains($d->one('SELECT rtreenode(2,data) FROM boxes_node WHERE nodeno=1'),'1'),'node decodes');
 $d->exec('BEGIN; DELETE FROM boxes WHERE id=1; ROLLBACK');$t->same(3,$d->one('SELECT count(*) FROM boxes'));
 $d->exec('UPDATE boxes SET x1=50,x2=60 WHERE id=2');$t->same('b',$d->one('SELECT label FROM boxes WHERE x1=50'));
 $t->throws(fn()=>$d->exec("INSERT INTO boxes VALUES(4,9,1,0,1,'bad')"));
 $d->exec('DELETE FROM boxes WHERE id=3');$t->same('ok',$d->one("SELECT rtreecheck('boxes')"));
});
perDriver($t,'dbstat/read-only-layout-aggregate-and-direct-only',function(Db $d)use($t){
 $d->exec('CREATE TABLE payload(id INTEGER PRIMARY KEY,data BLOB); CREATE INDEX payload_data ON payload(data)');
 $d->exec('INSERT INTO payload(data) VALUES(zeroblob(20000))');
 $rows=$d->rows("SELECT name,pagetype,pageno,pgsize,payload,unused FROM dbstat WHERE name='payload'");$t->ok(count($rows)>1,'overflow pages exposed');
 foreach($rows as $r){$t->ok($r['pageno']>0,'page number positive');$t->ok($r['pgsize']>=512,'valid page size');$t->ok($r['payload']>=0&&$r['unused']>=0,'nonnegative sizes');}
 $t->same(count($rows),$d->one("SELECT pageno FROM dbstat WHERE name='payload' AND aggregate=1"));
 $t->ok($d->one("SELECT sum(pgsize) FROM dbstat")>0,'size sum');$t->throws(fn()=>$d->exec('DELETE FROM dbstat'));
 $d->exec('CREATE VIEW forbidden AS SELECT * FROM dbstat');$t->throws(fn()=>$d->rows('SELECT * FROM forbidden'),'/unsafe|prohibited/i');
 $t->same('ok',$d->one('PRAGMA integrity_check'));
});

perDriver($t,'fts/fts4aux-rollback-contentless-diacritics',function(Db $d)use($t){
 $d->exec("CREATE VIRTUAL TABLE legacy USING fts4(body); INSERT INTO legacy VALUES('fox fox'),('fox bird'); CREATE VIRTUAL TABLE terms USING fts4aux(legacy)");
 $t->same(2,$d->one("SELECT documents FROM terms WHERE term='fox' AND col='*'"));$t->same(3,$d->one("SELECT occurrences FROM terms WHERE term='fox' AND col='*'"));
 $d->exec("CREATE VIRTUAL TABLE modern USING fts5(body,content='',contentless_delete=1); INSERT INTO modern(rowid,body) VALUES(1,'Café fox')");
 $t->same(1,$d->one("SELECT rowid FROM modern WHERE modern MATCH 'cafe'"));$d->exec("BEGIN; DELETE FROM modern WHERE rowid=1; ROLLBACK");$t->same(1,$d->one("SELECT count(*) FROM modern WHERE modern MATCH 'fox'"));$d->exec('DELETE FROM modern WHERE rowid=1');$t->same(0,$d->one("SELECT count(*) FROM modern WHERE modern MATCH 'fox'"));
});
perDriver($t,'spatial/float-rounding-multidimensional-and-rollback',function(Db $d)use($t){
 $d->exec('CREATE VIRTUAL TABLE volume USING rtree(id,x0,x1,y0,y1,z0,z1); INSERT INTO volume VALUES(1,0.1,0.3,0.1,0.3,0.1,0.3)');
 $r=$d->rows('SELECT * FROM volume')[0];$t->ok($r['x0']<=0.1&&$r['x1']>=0.3,'RTREE rounds bounds outward');$t->same([1],$d->column('SELECT id FROM volume WHERE x0<=0.2 AND x1>=0.2 AND y0<=0.2 AND y1>=0.2 AND z0<=0.2 AND z1>=0.2'));
 $d->exec('BEGIN; UPDATE volume SET x0=9,x1=10; ROLLBACK');$t->same('ok',$d->one("SELECT rtreecheck('volume')"));$t->near($r['x0'],$d->one('SELECT x0 FROM volume'));
});
