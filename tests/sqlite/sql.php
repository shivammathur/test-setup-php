<?php
perDriver($t,'sql/crud-bindings-injection-unicode-null-blob',function(Db $d)use($t){
 $d->exec('CREATE TABLE users(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL UNIQUE,age INTEGER DEFAULT 18,data BLOB,score REAL)');
 $attack="O'Reilly'); DROP TABLE users;-- é🙂";
 $d->rows('INSERT INTO users(name,data,score) VALUES(?,CAST(? AS BLOB),?)',[$attack,"\0\xffA",1.25]);
 $row=$d->rows('SELECT name,age,hex(data) AS blob,score FROM users WHERE id=?',[1])[0];
 $t->same($attack,$row['name']);$t->same(18,$row['age']);$t->same('00FF41',$row['blob']);$t->near(1.25,$row['score']);
 $t->same(1,$d->one('SELECT last_insert_rowid()'));$t->same(1,$d->one('SELECT changes()'));$t->same(1,$d->one('SELECT total_changes()'));
 $d->rows('UPDATE users SET age=:age,score=NULL WHERE id=:id',[':age'=>22,':id'=>1]);$t->same(null,$d->one('SELECT score FROM users'));
 $d->rows('INSERT INTO users(name) VALUES(?)', ['other']);$t->same([1,2],$d->column('SELECT id FROM users ORDER BY id'));
 $t->throws(fn()=>$d->rows('INSERT INTO users(name) VALUES(?)',[$attack]),'/unique/i');
 $d->exec('DELETE FROM users WHERE id=2');$t->same(1,$d->one('SELECT count(*) FROM users'));
});
perDriver($t,'sql/schema-constraints-generated-strict-without-rowid',function(Db $d)use($t){
 $d->exec('PRAGMA foreign_keys=ON; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER PRIMARY KEY,pid INTEGER REFERENCES parent(id) ON DELETE CASCADE,n INTEGER CHECK(n>=0),twice INTEGER GENERATED ALWAYS AS(n*2) STORED) STRICT');
 $d->exec('INSERT INTO parent VALUES(1); INSERT INTO child(id,pid,n) VALUES(1,1,5)');$t->same(10,$d->one('SELECT twice FROM child'));
 foreach(['INSERT INTO child(id,pid,n) VALUES(2,9,1)','INSERT INTO child(id,pid,n) VALUES(2,1,-1)',"INSERT INTO child(id,pid,n) VALUES(2,1,'bad')",'INSERT INTO child(id,pid,n,twice) VALUES(2,1,1,2)'] as $sql)$t->throws(fn()=>$d->exec($sql));
 $t->same([],$d->rows('PRAGMA foreign_key_check'));$d->exec('DELETE FROM parent WHERE id=1');$t->same(0,$d->one('SELECT count(*) FROM child'));
 $d->exec('CREATE TABLE kv(k TEXT PRIMARY KEY,v TEXT) WITHOUT ROWID');$d->exec("INSERT INTO kv VALUES('a','b')");$t->throws(fn()=>$d->one('SELECT rowid FROM kv'));
 $d->exec('ALTER TABLE kv ADD COLUMN extra INTEGER DEFAULT 7; ALTER TABLE kv RENAME COLUMN extra TO z; ALTER TABLE kv DROP COLUMN z; ALTER TABLE kv RENAME TO renamed');
 $t->same('b',$d->one("SELECT v FROM renamed WHERE k='a'"));$t->same(2,count($d->rows('PRAGMA table_info(renamed)')));
 $t->same(4,count($d->rows('PRAGMA table_xinfo(child)')));$t->same(1,count($d->rows('PRAGMA foreign_key_list(child)')));
});
perDriver($t,'sql/transactions-savepoints-conflicts-returning',function(Db $d)use($t){
 $d->exec('CREATE TABLE items(k TEXT PRIMARY KEY,v INTEGER); BEGIN IMMEDIATE');$d->exec("INSERT INTO items VALUES('a',1); SAVEPOINT inner1; UPDATE items SET v=2; ROLLBACK TO inner1; RELEASE inner1; COMMIT");$t->same(1,$d->one('SELECT v FROM items'));
 $d->exec("INSERT INTO items VALUES('a',3) ON CONFLICT(k) DO UPDATE SET v=excluded.v");$t->same(3,$d->one('SELECT v FROM items'));
 $d->exec("INSERT OR IGNORE INTO items VALUES('a',99)");$t->same(3,$d->one('SELECT v FROM items'));
 $d->exec("INSERT OR REPLACE INTO items VALUES('a',4)");$t->same(4,$d->one('SELECT v FROM items'));
 $t->same(5,$d->driver==='sqlite3'?$t->call($d->db,'querySingle',['UPDATE items SET v=v+1 RETURNING v']):$d->one('UPDATE items SET v=v+1 RETURNING v'));
 $d->exec('BEGIN; UPDATE items SET v=100; ROLLBACK');$t->same(5,$d->one('SELECT v FROM items'));
 $d->exec('BEGIN');$t->throws(fn()=>$d->exec('BEGIN'),'/transaction/i');$d->exec('ROLLBACK');
 $t->same('a',$d->driver==='sqlite3'?$t->call($d->db,'querySingle',['DELETE FROM items RETURNING k']):$d->one('DELETE FROM items RETURNING k'));$t->same(0,$d->one('SELECT count(*) FROM items'));
});
perDriver($t,'sql/joins-compounds-cte-subqueries-operators',function(Db $d)use($t){
 $d->exec("CREATE TABLE a(id INTEGER,v TEXT); INSERT INTO a VALUES(1,'a'),(2,'b'); CREATE TABLE b(id INTEGER,v TEXT); INSERT INTO b VALUES(2,'B'),(3,'C')");
 $t->same([2],$d->column('SELECT a.id FROM a JOIN b USING(id)'));$t->same([1,2,3],$d->column('SELECT coalesce(a.id,b.id) FROM a FULL OUTER JOIN b ON a.id=b.id ORDER BY 1'));
 $t->same([2,3],$d->column('SELECT b.id FROM a RIGHT JOIN b USING(id) ORDER BY b.id'));
 $t->same([1,2,3],$d->column('SELECT id FROM a UNION SELECT id FROM b ORDER BY id'));$t->same([1],$d->column('SELECT id FROM a EXCEPT SELECT id FROM b'));$t->same([2],$d->column('SELECT id FROM a INTERSECT SELECT id FROM b'));
 $t->same([2],$d->column('SELECT id FROM a WHERE EXISTS(SELECT 1 FROM b WHERE b.id=a.id)'));
 $t->same(55,$d->one('WITH RECURSIVE seq(n) AS(VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<10) SELECT sum(n) FROM seq'));
 $t->same([2],$d->column('WITH c AS MATERIALIZED(SELECT * FROM a) SELECT id FROM c ORDER BY id LIMIT 1 OFFSET 1'));
 foreach(['NULL IS NULL'=>1,'NULL IS NOT DISTINCT FROM NULL'=>1,'2 BETWEEN 1 AND 3'=>1,'2 IN(1,2,3)'=>1,'7 & 3'=>3,'1 << 3'=>8,'7 % 3'=>1,"'a'||'b'"=>'ab','CASE WHEN 1 THEN 9 ELSE 0 END'=>9,'CAST(\'12\' AS INTEGER)'=>12] as $expr=>$expected)$t->same($expected,$d->one('SELECT '.$expr));
});
perDriver($t,'sql/views-triggers-indexes-plans-analyze',function(Db $d)use($t){
 $d->exec('CREATE TABLE products(id INTEGER PRIMARY KEY,price INTEGER,name TEXT); CREATE TABLE audit(id INTEGER,old INTEGER,new INTEGER)');
 $d->exec('CREATE TRIGGER log_price AFTER UPDATE OF price ON products BEGIN INSERT INTO audit VALUES(new.id,old.price,new.price); END');
 $d->exec("INSERT INTO products VALUES(1,10,'A'); UPDATE products SET price=20; CREATE VIEW expensive AS SELECT * FROM products WHERE price>=20");
 $t->same([['id'=>1,'old'=>10,'new'=>20]],$d->rows('SELECT * FROM audit'));$t->same(1,$d->one('SELECT id FROM expensive'));
 $d->exec('CREATE INDEX by_price ON products(price); CREATE INDEX partial_price ON products(price) WHERE price>10; CREATE INDEX lower_name ON products(lower(name))');
 $t->same(3,count($d->rows('PRAGMA index_list(products)')));$t->ok(count($d->rows('PRAGMA index_xinfo(by_price)'))>=1,'index columns');
 $plan=$d->rows('EXPLAIN QUERY PLAN SELECT * FROM products INDEXED BY by_price WHERE price=20');$t->ok(str_contains($plan[0]['detail'],'by_price'),'index is selected');
 $t->ok(count($d->rows('EXPLAIN SELECT * FROM products'))>3,'bytecode emitted');$d->exec('ANALYZE; REINDEX by_price; PRAGMA optimize');$t->ok(count($d->rows('SELECT * FROM sqlite_stat1'))>0,'statistics generated');
 $d->exec('DROP VIEW expensive; DROP TRIGGER log_price; DROP INDEX lower_name');$t->same(2,count($d->rows('PRAGMA index_list(products)')));
});
perDriver($t,'sql/conflict-rollback-deferred-fk-and-recursive-trigger',function(Db $d)use($t){
 $d->exec('CREATE TABLE t(k UNIQUE); BEGIN; INSERT INTO t VALUES(1)');$t->throws(fn()=>$d->exec('INSERT OR ROLLBACK INTO t VALUES(1)'),'/unique/i');$t->same(0,$d->one('SELECT count(*) FROM t'));
 $d->exec('PRAGMA foreign_keys=ON; CREATE TABLE parent(k PRIMARY KEY); CREATE TABLE child(k REFERENCES parent(k) DEFERRABLE INITIALLY DEFERRED); BEGIN; INSERT INTO child VALUES(9)');$t->throws(fn()=>$d->exec('COMMIT'),'/foreign key/i');$d->exec('ROLLBACK');$t->same(0,$d->one('SELECT count(*) FROM child'));
 $d->exec('PRAGMA recursive_triggers=ON; CREATE TABLE counter(n); CREATE TRIGGER advance AFTER INSERT ON counter WHEN new.n<3 BEGIN INSERT INTO counter VALUES(new.n+1); END; INSERT INTO counter VALUES(1)');$t->same([1,2,3],$d->column('SELECT n FROM counter ORDER BY n'));
});
