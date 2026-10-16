$env:TEST_PHP_EXECUTABLE = $env:PHP_TEST_BINARY
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$tests = @(Get-ChildItem ext/standard/tests/general_functions/proc_open*.phpt | ForEach-Object FullName)
$failed = $false
foreach ($mode in @('no-ini', 'tracing-jit')) {
    $dir = ".validation/results/proc-open-$mode"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $options = @('-n')
    if ($mode -eq 'tracing-jit') {
        $options += @('-d', 'zend_extension=C:/obj/Release_TS/php_opcache.dll', '-d', 'opcache.enable_cli=1', '-d', 'opcache.protect_memory=1', '-d', 'opcache.jit_buffer_size=64M', '-d', 'opcache.jit=tracing')
    }
    & $env:PHP_TEST_BINARY -n run-tests.php @options --no-progress --no-color --show-diff -q -W "$dir/results.txt" @tests 2>&1 | Tee-Object "$dir/run.log"
    $code = $LASTEXITCODE
    $code | Set-Content "$dir/exit-code.txt"
    foreach ($test in $tests) {
        $stem = [IO.Path]::ChangeExtension($test, $null).TrimEnd('.')
        foreach ($suffix in @('.out', '.diff', '.log', '.exp')) {
            if (Test-Path "$stem$suffix") { Copy-Item "$stem$suffix" $dir }
        }
    }
    if ($code -ne 0) { $failed = $true }
    $results = Get-Content "$dir/results.txt" -Raw
    foreach ($name in @('proc_open_null.phpt', 'proc_open_redirect.phpt')) {
        if ($results -notmatch "(?m)^PASSED\s+.*$([regex]::Escape($name))\r?$") { throw "$name did not pass in $mode" }
    }
}
if ($failed) { throw 'Focused proc_open test failures' }
$global:LASTEXITCODE = 0
