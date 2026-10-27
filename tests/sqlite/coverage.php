<?php
$t->test('coverage/public-api-inventory',function()use($t){
 $manifest=json_decode(file_get_contents(__DIR__.'/api-manifest.json'),true,512,JSON_THROW_ON_ERROR);$minor=PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;
 $t->ok(isset($manifest[$minor]),'PHP version has explicit API inventory');$missing=[];
 foreach($manifest[$minor]['classes'] as $class=>$expected){$actual=[];foreach((new ReflectionClass($class))->getMethods(ReflectionMethod::IS_PUBLIC) as $m)if($class!=='Pdo\\Sqlite'||$m->getDeclaringClass()->getName()===$class)$actual[]=$m->name;sort($actual);sort($expected);$t->same($expected,$actual,$class.' public surface changed');foreach($expected as $method)if(empty($t->api[$class.'::'.$method]))$missing[]=$class.'::'.$method;}
 foreach(['sqliteCreateFunction','sqliteCreateAggregate','sqliteCreateCollation'] as $method)if(empty($t->api['PDO::'.$method]))$missing[]='PDO::'.$method;
 $t->same([],$missing,'Untested public methods');
});
foreach(drivers() as $driver)$t->test($driver.'/coverage/sql-functions',function()use($t,$driver){
 $names=array_unique(array_column($t->inventory[$driver]['functions']??[],'name'));$t->ok(count($names)>150,'function inventory complete');$missing=[];
 foreach($names as $name){if(PHP_OS_FAMILY!=='Windows'&&str_starts_with($name,'geopoly_'))continue;if(empty($t->functions[$driver][$name]))$missing[]=$name;}
 sort($missing);$t->same([],$missing,'Functions without submitted SQL tests');
});

foreach(drivers() as $driver)$t->test($driver.'/coverage/virtual-table-modules',function()use($t,$driver){
 $names=array_column($t->inventory[$driver]['modules']??[],'name');$expected=['dbstat','fts3','fts3tokenize','fts4','fts4aux','fts5','fts5vocab','rtree','rtree_i32'];if(PHP_OS_FAMILY!=='Windows')$names=array_values(array_diff($names,['geopoly']));sort($names);sort($expected);$t->same($expected,$names,'module surface');foreach($expected as $module)$t->ok(!empty($t->modules[$driver][$module]),$module.' has behavior tests');
});
