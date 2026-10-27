<?php
declare(strict_types=1);

final class Suite {
    public array $results = [], $api = [], $functions = [], $inventory = [], $modules = [];
    public int $assertions = 0;
    public string $current = '';
    public function test(string $name, callable $test): void {
        $this->current = $name; $start = microtime(true); $before = $this->assertions;
        try { $test(); $status = 'pass'; $error = null; }
        catch (Throwable $e) { $status = 'fail'; $error = get_class($e).': '.$e->getMessage().' at '.$e->getFile().':'.$e->getLine(); }
        $this->results[] = ['name'=>$name, 'status'=>$status, 'assertions'=>$this->assertions-$before, 'seconds'=>microtime(true)-$start, 'error'=>$error];
        echo strtoupper($status).' '.$name.($error ? ': '.$error : '')."\n";
    }
    public function same(mixed $expected, mixed $actual, string $message = ''): void {
        $this->assertions++;
        if ($expected !== $actual) throw new RuntimeException($message.' expected '.var_export($expected,true).'; got '.var_export($actual,true));
    }
    public function ok(bool $condition, string $message): void { $this->same(true,$condition,$message); }
    public function near(float $expected, mixed $actual, float $tolerance = 1e-10): void {
        $this->assertions++;
        if (!is_numeric($actual) || !is_finite((float)$actual) || abs($expected-(float)$actual)>$tolerance*max(1,abs($expected))) throw new RuntimeException("Expected ~$expected; got ".var_export($actual,true));
    }
    public function throws(callable $operation, string $pattern = '', string $class = Throwable::class): Throwable {
        $this->assertions++;
        try { $operation(); } catch (Throwable $e) {
            if (!$e instanceof $class || ($pattern!=='' && !preg_match($pattern,$e->getMessage()))) throw new RuntimeException('Unexpected exception: '.get_class($e).': '.$e->getMessage());
            return $e;
        }
        throw new RuntimeException('Expected an exception');
    }
    public function touch(string $method): void { $this->api[$method][$this->current] = true; }
    public function call(object|string $object, string $method, array $args = []): mixed {
        $r = new ReflectionMethod($object,$method); $this->touch($r->getDeclaringClass()->getName().'::'.$method);
        return call_user_func_array([$object,$method],$args);
    }
    public function sql(string $driver, string $sql): void {
        preg_match_all('/CREATE\s+VIRTUAL\s+TABLE\s+\w+\s+USING\s+(\w+)/i',$sql,$modules);foreach($modules[1] as $module)$this->modules[$driver][strtolower($module)][$this->current]=true;
        if(preg_match('/\bFROM\s+dbstat\b/i',$sql))$this->modules[$driver]['dbstat'][$this->current]=true;
        // Record only actual SQL submitted to the engine; inventory compares this to function_list.
        $sql=preg_replace("~'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"|--[^\\r\\n]*|/\\*.*?\\*/~s",' ',$sql);
        preg_match_all('/\b([a-z_][a-z_0-9]*)\s*\(/i',$sql,$matches);
        foreach ($matches[1] as $name) $this->functions[$driver][strtolower($name)][$this->current] = true;
        foreach (['current_date','current_time','current_timestamp'] as $name) if (preg_match('/\b'.$name.'\b/i',$sql)) $this->functions[$driver][$name][$this->current]=true;
        foreach (['->>','->'] as $name) if (str_contains($sql,$name)) $this->functions[$driver][$name][$this->current]=true;
    }
    public function report(string $dir): int {
        if (!is_dir($dir)) mkdir($dir,0777,true);
        $failures = count(array_filter($this->results,fn($r)=>$r['status']==='fail'));
        $report=['php'=>PHP_VERSION,'sqlite'=>SQLite3::version(),'os'=>PHP_OS_FAMILY,'bits'=>PHP_INT_SIZE*8,'zts'=>PHP_ZTS,'opcache'=>ini_get('opcache.enable_cli'),'assertions'=>$this->assertions,'tests'=>count($this->results),'failures'=>$failures,'results'=>$this->results,'api_coverage'=>$this->api,'module_coverage'=>$this->modules,'function_coverage'=>$this->functions,'inventory'=>$this->inventory];
        file_put_contents($dir.'/results.json',json_encode($report,JSON_PRETTY_PRINT|JSON_THROW_ON_ERROR|JSON_INVALID_UTF8_SUBSTITUTE)."\n");
        $esc=fn($s)=>htmlspecialchars((string)$s,ENT_XML1|ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8');
        $xml='<?xml version="1.0" encoding="UTF-8"?>'."\n".'<testsuite name="SQLite userland" tests="'.count($this->results).'" failures="'.$failures.'">';
        foreach($this->results as $r) {$xml.='<testcase name="'.$esc($r['name']).'" time="'.$r['seconds'].'">';if($r['error'])$xml.='<failure message="'.$esc($r['error']).'"/>';$xml.='</testcase>';}
        file_put_contents($dir.'/junit.xml',$xml.'</testsuite>');
        echo 'TOTAL '.count($this->results).' tests, '.$this->assertions.' assertions, '.$failures." failures\n";
        return $failures ? 1 : 0;
    }
}
final class Db {
    public SQLite3|PDO $db;
    public function __construct(public Suite $t, public string $driver, string $path=':memory:', array $options=[]) {
        if ($driver==='sqlite3') { $t->touch('SQLite3::__construct'); $this->db=new SQLite3($path,$options['flags']??(SQLITE3_OPEN_READWRITE|SQLITE3_OPEN_CREATE)); $t->call($this->db,'enableExceptions',[true]); }
        else { $t->touch('PDO::__construct'); $class=$driver==='pdo-class'?'Pdo\\Sqlite':'PDO'; $this->db=new $class('sqlite:'.$path,null,null,$options+[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]); }
    }
    public function exec(string $sql): mixed { $this->t->sql($this->driver,$sql);return $this->t->call($this->db,'exec',[$sql]); }
    public function rows(string $sql, array $params=[]): array {
        $this->t->sql($this->driver,$sql);
        if ($this->db instanceof SQLite3) {
            $stmt=$this->t->call($this->db,'prepare',[$sql]);
            foreach($params as $key=>$value) $this->t->call($stmt,'bindValue',[is_int($key)?$key+1:$key,$value,is_int($value)?SQLITE3_INTEGER:(is_float($value)?SQLITE3_FLOAT:($value===null?SQLITE3_NULL:SQLITE3_TEXT))]);
            $result=$this->t->call($stmt,'execute');$rows=[];
            // SQLite3 executes non-result statements in execute(); fetching would run them again.
            if ($result->numColumns()===0) {$this->t->call($result,'finalize');$this->t->call($stmt,'close');return [];}
            while(($row=$this->t->call($result,'fetchArray',[SQLITE3_ASSOC]))!==false) $rows[]=$row;
            $this->t->call($result,'finalize');$this->t->call($stmt,'close');return $rows;
        }
        $stmt=$this->t->call($this->db,'prepare',[$sql]);$this->t->call($stmt,'execute',[$params]);$rows=$this->t->call($stmt,'fetchAll',[PDO::FETCH_ASSOC]);$this->t->call($stmt,'closeCursor');return $rows;
    }
    public function one(string $sql, array $params=[]): mixed { $rows=$this->rows($sql,$params);return $rows ? reset($rows[0]) : null; }
    public function column(string $sql): array {return array_map(fn($r)=>reset($r),$this->rows($sql));}
}
function pathFor(string $name): string { return $GLOBALS['work'].'/'.preg_replace('/[^a-z0-9_.-]/i','_',$name).'.db'; }
function drivers(): array {return class_exists('Pdo\\Sqlite')?['sqlite3','pdo','pdo-class']:['sqlite3','pdo'];}
function perDriver(Suite $t,string $name,callable $test): void {foreach(drivers() as $driver)$t->test($driver.'/'.$name,fn()=>$test(new Db($t,$driver),$driver));}

function pdoConstant(string $name): int {return constant(PHP_VERSION_ID>=80400?'Pdo\\Sqlite::'.$name:'PDO::SQLITE_'.$name);}
function expectedDeprecation(Suite $t, callable $fn): mixed {
 $seen=[];set_error_handler(function($severity,$message)use(&$seen){if($severity!==E_DEPRECATED)throw new ErrorException($message,0,$severity);$seen[]=$message;return true;});
 try{$value=$fn();}finally{restore_error_handler();}
 $t->same(PHP_VERSION_ID>=80500?1:0,count($seen),'documented legacy PDO deprecation');return $value;
}
