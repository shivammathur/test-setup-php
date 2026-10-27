<?php
$scalarCases=[
 'abs'=>['abs(-42)',42], 'char'=>["char(65,233,128578)",'Aé🙂'], 'coalesce'=>["coalesce(NULL,NULL,'yes')",'yes'],
 'concat'=>["concat('a',NULL,'b')",'ab'], 'concat_ws'=>["concat_ws('-', 'a',NULL,'b')",'a-b'],
 'format'=>["format('%04d:%s',7,'x')",'0007:x'], 'printf'=>["printf('%04d:%s',7,'x')",'0007:x'],
 'glob'=>["glob('a[bc]*','abc')",1], 'if'=>["if(0,'x',1,'y','z')",'y'], 'iif'=>["iif(0,'x',1,'y','z')",'y'],
 'ifnull'=>["ifnull(NULL,'fallback')",'fallback'], 'instr'=>["instr('éabc','b')",3], 'length'=>["length('é🙂')",2],
 'octet_length'=>["octet_length('é🙂')",6], 'like'=>["like('a!_%','a_xyz','!')",1], 'lower'=>["lower('AbC')",'abc'],
 'upper'=>["upper('AbC')",'ABC'], 'ltrim'=>["ltrim('..abc..','.')",'abc..'], 'rtrim'=>["rtrim('..abc..','.')",'..abc'],
 'trim'=>["trim('..abc..','.')",'abc'], 'max'=>['max(2,9,3)',9], 'min'=>['min(2,9,3)',2],
 'nullif'=>['nullif(4,4)',null], 'quote'=>["quote('O''Reilly')","'O''Reilly'"],
 'replace'=>["replace('abcabc','bc','X')",'aXaX'], 'round'=>['round(2.345,2)',2.35], 'sign'=>['sign(-50)',-1],
 'substr'=>["substr('aé🙂z',2,2)",'é🙂'], 'substring'=>["substring('aé🙂z',-2)",'🙂z'],
 'typeof'=>["typeof(x'0001')",'blob'], 'unicode'=>["unicode('🙂')",128578], 'hex'=>["hex(x'00ff41')",'00FF41'],
 'unhex'=>["hex(unhex('00:FF:41',':'))",'00FF41'], 'unistr'=>["unistr('A\\u00E9\\U0001F642')",'Aé🙂'],
 'unistr_quote'=>["unistr_quote('O''Reilly')","'O''Reilly'"], 'zeroblob'=>['length(zeroblob(37))',37],
 'likelihood'=>['likelihood(7,0.1)',7], 'likely'=>['likely(7)',7], 'unlikely'=>['unlikely(7)',7],
 'sqlite_log'=>["sqlite_log(0,'sqlite userland QA')",null], 'subtype'=>["subtype(json('{}'))",74],
];
foreach($scalarCases as $name=>[$expr,$expected])perDriver($t,'scalar/'.$name,function(Db $d)use($t,$expr,$expected){$actual=$d->one('SELECT '.$expr);is_float($expected)?$t->near($expected,$actual):$t->same($expected,$actual);});
perDriver($t,'scalar/null-binary-and-errors',function(Db $d)use($t){
 foreach(['abs(NULL)','lower(NULL)','unicode(NULL)','unhex(\'invalid\')','concat_ws(NULL,1,2)','min(1,NULL)','max(1,NULL)'] as $expr)$t->same(null,$d->one('SELECT '.$expr));
 $t->same('', $d->one("SELECT concat(NULL,NULL)"));$t->same('NULL',$d->one('SELECT quote(NULL)'));
 $t->same("X'00FF'",$d->one("SELECT quote(x'00ff')"));$t->same('a',$d->one("SELECT substr('abc',1,1)"));
 $t->throws(fn()=>$d->one('SELECT abs(-9223372036854775808)'),'/overflow/i');
 $t->same('integer',$d->one('SELECT typeof(random())'));$r=$d->one('SELECT randomblob(64)');$t->same(64,strlen($r));$t->ok($r!==$d->one('SELECT randomblob(64)'),'independent random blobs');
 $t->same(1,$d->one("SELECT 'Mixed' LIKE 'mixed'"));$t->same(0,$d->one("SELECT 'Mixed' GLOB 'mixed'"));
});
$mathCases=[
 'acos'=>['acos(1)',0.0], 'acosh'=>['acosh(1)',0.0], 'asin'=>['asin(1)',M_PI/2], 'asinh'=>['asinh(0)',0.0],
 'atan'=>['atan(1)',M_PI/4], 'atan2'=>['atan2(1,0)',M_PI/2], 'atanh'=>['atanh(0)',0.0],
 'ceil'=>['ceil(-1.2)',-1.0], 'ceiling'=>['ceiling(1.2)',2.0], 'floor'=>['floor(-1.2)',-2.0],
 'cos'=>['cos(0)',1.0], 'cosh'=>['cosh(0)',1.0], 'degrees'=>['degrees(pi())',180.0], 'exp'=>['exp(0)',1.0],
 'ln'=>['ln(exp(1))',1.0], 'log'=>['log(2,8)',3.0], 'log10'=>['log10(1000)',3.0], 'log2'=>['log2(8)',3.0],
 'mod'=>['mod(7.5,2)',1.5], 'pi'=>['pi()',M_PI], 'pow'=>['pow(2,10)',1024.0], 'power'=>['power(9,0.5)',3.0],
 'radians'=>['radians(180)',M_PI], 'sin'=>['sin(pi()/2)',1.0], 'sinh'=>['sinh(0)',0.0], 'sqrt'=>['sqrt(81)',9.0],
 'tan'=>['tan(0)',0.0], 'tanh'=>['tanh(0)',0.0], 'trunc'=>['trunc(-1.9)',-1.0],
];
foreach($mathCases as $name=>[$expr,$expected])perDriver($t,'math/'.$name,function(Db $d)use($t,$name,$expr,$expected){
 $t->near($expected,$d->one('SELECT '.$expr));
 if($name!=='pi'){$args=in_array($name,['atan2','mod','pow','power'])?'NULL,2':($name==='log'?'NULL':'NULL');$t->same(null,$d->one("SELECT $name($args)"));}
});
perDriver($t,'math/domain-coercion-and-precision',function(Db $d)use($t){
 foreach(['sqrt(-1)','acos(2)','asin(-2)','acosh(0)','atanh(2)','ln(0)','log10(-2)','log(1,8)','pow(-2,0.5)','mod(1,0)',"sqrt('no')","sqrt(x'31')"] as $expr)$t->same(null,$d->one('SELECT '.$expr),$expr);
 $t->near(2,$d->one('SELECT log(100)'));$t->near(3,$d->one("SELECT sqrt('9')"));$t->near(1,$d->one('SELECT pow(sin(0.7),2)+pow(cos(0.7),2)'));
});
$dateCases=[
 'date'=>["date('2024-02-29','+1 year','floor')",'2025-02-28'], 'time'=>["time('2000-01-01 23:59:59','+1 second')",'00:00:00'],
 'datetime'=>["datetime(0,'unixepoch')",'1970-01-01 00:00:00'], 'julianday'=>["julianday('2000-01-01 12:00:00')",2451545.0],
 'unixepoch'=>["unixepoch('1970-01-02 00:00:00')",86400], 'strftime'=>["strftime('%Y-%m-%d %H:%M:%S','2024-02-29 12:34:56')",'2024-02-29 12:34:56'],
 'timediff'=>["timediff('2024-02-01','2024-01-01')",'+0000-01-00 00:00:00.000'],
];
foreach($dateCases as $name=>[$expr,$expected])perDriver($t,'date/'.$name,function(Db $d)use($t,$expr,$expected){is_float($expected)?$t->near($expected,$d->one('SELECT '.$expr)):$t->same($expected,$d->one('SELECT '.$expr));});
perDriver($t,'date/current-modifiers-null-invalid',function(Db $d)use($t){
 foreach(['current_date'=>'/^\d{4}-\d{2}-\d{2}$/','current_time'=>'/^\d{2}:\d{2}:\d{2}$/','current_timestamp'=>'/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/'] as $expr=>$pattern)$t->same(1,preg_match($pattern,$d->one('SELECT '.$expr)));
 $t->same('2024-03-01',$d->one("SELECT date('2024-02-15','start of month','+1 month')"));$t->same(null,$d->one("SELECT datetime('invalid')"));$t->same(null,$d->one('SELECT date(NULL)'));
 $t->near(0.125,$d->one("SELECT unixepoch('1970-01-01 00:00:00.125','subsec')"));
});
perDriver($t,'aggregate/all-functions-distinct-filter-order-empty',function(Db $d)use($t){
 $d->exec('CREATE TABLE n(x); INSERT INTO n VALUES(1),(2),(2),(5),(NULL)');
 foreach(['sum(x)'=>10,'total(x)'=>10.0,'avg(x)'=>2.5,'count(x)'=>4,'count(*)'=>5,'min(x)'=>1,'max(x)'=>5,'sum(DISTINCT x)'=>8,'sum(x) FILTER(WHERE x>2)'=>5,"group_concat(x,':' ORDER BY x DESC)"=>'5:2:2:1',"string_agg(x,':' ORDER BY x)"=>'1:2:2:5'] as $expr=>$expected){$v=$d->one('SELECT '.$expr.' FROM n');is_float($expected)?$t->near($expected,$v):$t->same($expected,$v);}
 foreach(['sum','avg','min','max','group_concat'] as $fn)$t->same(null,$d->one("SELECT $fn(x) FROM n WHERE 0"));$t->near(0,$d->one('SELECT total(x) FROM n WHERE 0'));
});
$windowCases=[
 'row_number'=>['row_number() OVER(ORDER BY x)',[1,2,3,4]],'rank'=>['rank() OVER(ORDER BY x)',[1,2,2,4]],
 'dense_rank'=>['dense_rank() OVER(ORDER BY x)',[1,2,2,3]],'ntile'=>['ntile(2) OVER(ORDER BY x)',[1,1,2,2]],
 'percent_rank'=>['percent_rank() OVER(ORDER BY x)',[0.0,1/3,1/3,1.0]],'cume_dist'=>['cume_dist() OVER(ORDER BY x)',[0.25,0.75,0.75,1.0]],
 'lag'=>['lag(x,1,-1) OVER(ORDER BY x)',[-1,1,2,2]],'lead'=>['lead(x,1,-1) OVER(ORDER BY x)',[2,2,5,-1]],
 'first_value'=>['first_value(x) OVER(ORDER BY x)',[1,1,1,1]],'last_value'=>['last_value(x) OVER(ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)',[5,5,5,5]],
 'nth_value'=>['nth_value(x,2) OVER(ORDER BY x ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)',[2,2,2,2]],
];
foreach($windowCases as $name=>[$expr,$expected])perDriver($t,'window/'.$name,function(Db $d)use($t,$expr,$expected){$actual=$d->column('WITH n(x) AS(VALUES(1),(2),(2),(5)) SELECT '.$expr.' FROM n ORDER BY x');$t->same(count($expected),count($actual));foreach($expected as $i=>$v)is_float($v)?$t->near($v,$actual[$i]):$t->same($v,$actual[$i]);});
perDriver($t,'percentile/values-boundaries-group-window-errors',function(Db $d)use($t){
 $d->exec('CREATE TABLE n(x,g); INSERT INTO n VALUES(10,1),(20,1),(30,1),(40,1),(NULL,1),(5,2)');
 foreach(['median(x)'=>25.0,'percentile(x,50)'=>25.0,'percentile_cont(x,0.25)'=>17.5,'percentile_disc(x,0.25)'=>10.0,'percentile(x,0)'=>10.0,'percentile(x,100)'=>40.0] as $expr=>$expected)$t->near($expected,$d->one('SELECT '.$expr.' FROM n WHERE g=1'));
 $t->same([25.0,5.0],array_map('floatval',$d->column('SELECT median(x) FROM n GROUP BY g ORDER BY g')));
 $t->same(null,$d->one('SELECT median(x) FROM n WHERE 0'));
 $t->same([10.0,15.0,20.0,30.0],array_map('floatval',$d->column('SELECT median(x) OVER(ORDER BY x ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) FROM n WHERE g=1 AND x IS NOT NULL ORDER BY x')));
 foreach(['percentile(x,-1)','percentile(x,101)','percentile_cont(x,2)','percentile(x,NULL)','percentile(x,x)'] as $expr)$t->throws(fn()=>$d->one('SELECT '.$expr.' FROM n WHERE g=1'));
 $t->throws(fn()=>$d->one("SELECT median('bad')"));$t->throws(fn()=>$d->one('SELECT median(1e999)'));
 $t->near(5000.5,$d->one('WITH RECURSIVE seq(n) AS(VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<10000) SELECT median(n) FROM seq'));
});
