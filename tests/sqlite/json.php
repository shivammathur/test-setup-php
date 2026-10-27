<?php
$jsonCases=[
 'json'=>["json('{ \"a\": 1 }')",'{"a":1}'], 'json_array'=>["json_array(1,'x',NULL)",'[1,"x",null]'],
 'json_object'=>["json_object('a',1,'b',json('[2]'))",'{"a":1,"b":[2]}'],
 'json_array_length'=>["json_array_length('{\"a\":[1,2]}','$.a')",2],
 'json_extract'=>["json_extract('{\"a\":[1,2]}','$.a[1]')",2],
 'json_insert'=>["json_insert('{\"a\":1}','$.a',9,'$.b',2)",'{"a":1,"b":2}'],
 'json_replace'=>["json_replace('{\"a\":1}','$.a',9,'$.b',2)",'{"a":9}'],
 'json_set'=>["json_set('{\"a\":1}','$.a',9,'$.b',2)",'{"a":9,"b":2}'],
 'json_remove'=>["json_remove('{\"a\":1,\"b\":2}','$.a')",'{"b":2}'],
 'json_patch'=>["json_patch('{\"a\":1,\"b\":2}','{\"a\":null,\"c\":3}')",'{"b":2,"c":3}'],
 'json_type'=>["json_type('{\"a\":null}','$.a')",'null'], 'json_valid'=>["json_valid('{\"a\":1}')",1],
 'json_error_position'=>["json_error_position('{bad')",5], 'json_quote'=>["json_quote('a\"b')",'"a\\"b"'],
 'json_pretty'=>["json_pretty('{\"a\":1}','  ')","{\n  \"a\": 1\n}"],
 'json_array_insert'=>["json_array_insert('[1,3]','$[1]',2)",'[1,2,3]'],
 'jsonb'=>["json(jsonb('{\"a\":1}'))",'{"a":1}'],
 'jsonb_array'=>["json(jsonb_array(1,'x',NULL))",'[1,"x",null]'],
 'jsonb_object'=>["json(jsonb_object('a',1))",'{"a":1}'],
 'jsonb_extract'=>["json(jsonb_extract('{\"a\":[1,2]}','$.a'))",'[1,2]'],
 'jsonb_insert'=>["json(jsonb_insert('{\"a\":1}','$.b',2))",'{"a":1,"b":2}'],
 'jsonb_replace'=>["json(jsonb_replace('{\"a\":1}','$.a',2))",'{"a":2}'],
 'jsonb_set'=>["json(jsonb_set('{\"a\":1}','$.b',2))",'{"a":1,"b":2}'],
 'jsonb_remove'=>["json(jsonb_remove('{\"a\":1}','$.a'))",'{}'],
 'jsonb_patch'=>["json(jsonb_patch('{\"a\":1}','{\"a\":2}'))",'{"a":2}'],
 'jsonb_array_insert'=>["json(jsonb_array_insert('[1,3]','$[1]',2))",'[1,2,3]'],
];
foreach($jsonCases as $name=>[$expr,$expected])perDriver($t,'json/'.$name,fn(Db $d)=>$t->same($expected,$d->one('SELECT '.$expr)));
perDriver($t,'json/aggregates-table-functions-operators',function(Db $d)use($t){
 $d->exec("CREATE TABLE j(k,v); INSERT INTO j VALUES('a',1),('b',2)");
 foreach(['json_group_array','jsonb_group_array'] as $fn)$t->same('[1,2]',$d->one("SELECT json($fn(v ORDER BY k)) FROM j"));
 foreach(['json_group_object','jsonb_group_object'] as $fn)$t->same('{"a":1,"b":2}',$d->one("SELECT json($fn(k,v ORDER BY k)) FROM j"));
 $t->same([1,2],$d->column("SELECT value FROM json_each('[1,2]') ORDER BY key"));
 $t->same([1,2],$d->column("SELECT atom FROM json_tree('{\"a\":[1,2]}') WHERE atom IS NOT NULL ORDER BY id"));
 $t->same('[1,2]',$d->one("SELECT json(value) FROM jsonb_each('{\"a\":[1,2]}')"));
 $t->same([1,2],$d->column("SELECT atom FROM jsonb_tree('{\"a\":[1,2]}') WHERE atom IS NOT NULL ORDER BY id"));
 $t->same('"x"',$d->one("SELECT '{\"a\":\"x\"}' -> '$.a'"));$t->same('x',$d->one("SELECT '{\"a\":\"x\"}' ->> '$.a'"));
 $t->same(2,$d->one("SELECT '[1,2]' ->> -1"));$t->same(null,$d->one("SELECT json_extract('{}','$.missing')"));
});
perDriver($t,'json/roundtrip-json5-binary-errors',function(Db $d)use($t){
 $doc=['unicode'=>'é🙂','quote'=>"\"\\\n",'nested'=>[null,true,false,0,1.25]];$encoded=json_encode($doc,JSON_THROW_ON_ERROR);
 $t->same($doc,json_decode($d->one('SELECT json(jsonb(?))',[$encoded]),true,512,JSON_THROW_ON_ERROR));
 $t->same('{"a":1}',$d->one("SELECT json('{a:1,}')"));$t->same(1,$d->one("SELECT json_valid('{a:1,}',2)"));
 $t->same(0,$d->one("SELECT json_valid('{bad')"));$t->same('blob',$d->one("SELECT typeof(jsonb('{}'))"));
 $t->same(1,$d->one("SELECT json_valid(jsonb('{}'),8)"));
 $t->throws(fn()=>$d->one("SELECT json('{bad')"),'/malformed/i');$t->throws(fn()=>$d->one("SELECT json_extract('{}','bad-path')"));
 $t->throws(fn()=>$d->one("SELECT json_object(NULL,1)"));$t->throws(fn()=>$d->one("SELECT json_array(x'ff')"));
 $t->throws(fn()=>$d->one("SELECT json_valid('{}',0)"));
 $t->same(null,$d->one('SELECT json(NULL)'));
});
