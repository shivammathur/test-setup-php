<?php
declare(strict_types=1);

// Exercise GH-24185 with a parent keeping OPcache SHM alive while workers attach.
function fixedArrayRead(SplFixedArray $array, int $index): mixed
{
    return $array->offsetGet($index);
}
function makeDate(string $value): DateTimeImmutable
{
    return new DateTimeImmutable($value);
}
function iteratorSeek(ArrayIterator $iterator, int $position): void
{
    $iterator->seek($position);
}
function hotSum(int $value): int
{
    for ($i = 0; $i < 1000; $i++) {
        $value = ($value + $i) & 65535;
    }
    return $value;
}
$jit = opcache_get_status(false)['jit'] ?? [];
if (empty($jit['on'])) {
    throw new RuntimeException('JIT must be active for the regression check');
}
if (($argv[1] ?? '') === '--child') {
    $caught = 0;
    $array = new SplFixedArray(1);
    $iterator = new ArrayIterator([1]);
    for ($i = 0; $i < 100; $i++) {
        hotSum($i);
        try { fixedArrayRead($array, 5); } catch (RuntimeException $e) { $caught++; }
        try { makeDate('not a date'); } catch (Exception $e) { $caught++; }
        try { iteratorSeek($iterator, 5); } catch (OutOfBoundsException $e) { $caught++; }
    }
    echo "caught $caught\n";
    exit($caught === 300 ? 0 : 1);
}
$ini = php_ini_loaded_file();
if (!$ini) { throw new RuntimeException('Regression test requires an explicit INI'); }
foreach ([false, true] as $suppress) {
    for ($i = 0; $i < 50; $i++) {
        $cmd = 'start "" /b /wait "' . PHP_BINARY . '" -n -c "' . $ini .
            '" "' . __FILE__ . '" --child & exit';
        $process = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes, __DIR__, getenv(), ['suppress_errors' => $suppress]);
        if (!is_resource($process)) { throw new RuntimeException('Cannot start child'); }
        fclose($pipes[0]);
        $stdout = stream_get_contents($pipes[1]);
        $stderr = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $exit = proc_close($process);
        if ($exit !== 0 || trim($stdout) !== 'caught 300' || trim($stderr) !== '') {
            throw new RuntimeException("Child $i suppress=$suppress exit=$exit stdout=$stdout stderr=$stderr");
        }
    }
}
echo "100 children passed; JIT kind=" . $jit['kind'] . "\n";
