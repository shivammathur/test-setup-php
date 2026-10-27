<?php
require __DIR__.'/harness.php';
$s=new Suite();$s->current='lexer';$s->sql('fixture',"SELECT abs(-1), 'fake(1)', \"quoted(1)\" /* nope(2) */ -- ignored(1)\n, pi()");
$s->same(['abs','pi'],array_keys($s->functions['fixture']));
$s->throws(fn()=>$s->same(1,'1'));$s->throws(fn()=>$s->near(1,2));$s->throws(fn()=>$s->near(1,NAN));$s->throws(fn()=>$s->throws(fn()=>1));
ob_start();$s->test('intentional-binary-failure',fn()=>$s->same("\xff",'different'));$code=$s->report($argv[1]);ob_end_clean();
$s->same(1,$code);$report=json_decode(file_get_contents($argv[1].'/results.json'),true,512,JSON_THROW_ON_ERROR);$s->same(1,$report['failures']);
echo "PASS harness self-test: SQL lexer, strict assertions, exception assertions, binary diagnostics, JSON and failure exit\n";
