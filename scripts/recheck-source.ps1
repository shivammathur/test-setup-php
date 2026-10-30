$ErrorActionPreference = 'Stop'
$row = $env:RECHECK_ROW | ConvertFrom-Json
if ($row.test_type -notin @('php', 'ext')) { throw 'Invalid test environment' }
$archive = Join-Path $PWD "artifacts/$($row.runtime_name)"
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $row.runtime_sha256) { throw 'Runtime archive hash mismatch' }
$work = Join-Path $PWD 'recheck'
$bin = Join-Path $work 'phpbin'
$reports = Join-Path $PWD 'reports'
New-Item $reports -ItemType Directory -Force | Out-Null
Expand-Archive $archive -DestinationPath $bin -Force
$php = Join-Path $bin 'php.exe'
Import-Module ./builder/php/BuildPhp -Force
& (Get-Module BuildPhp) {
    param($directory, $arch, $mode, $type)
    Set-PhpIniForTests -BuildDirectory $directory -Arch $arch -Opcache $mode -TestType $type
} $work $row.arch $row.opcache $row.test_type
$gdLoaded = & $php -c "$bin/php-test.ini" -r 'echo extension_loaded("gd") ? "1" : "0";'
if ($LASTEXITCODE -or $gdLoaded -ne '0') { throw "Focused HTTP/CLI recheck unexpectedly loaded GD (output: $gdLoaded, exit: $LASTEXITCODE)" }
$env:PATH = "$bin;$env:PATH"
$env:TEST_PHP_EXECUTABLE = $php
$env:TEST_PHP_CGI_EXECUTABLE = Join-Path $bin 'php-cgi.exe'
$env:TEST_PHPDBG_EXECUTABLE = Join-Path $bin 'phpdbg.exe'
$env:TEST_PHP_JUNIT = Join-Path $reports 'source-recheck.xml'
$env:SKIP_IO_CAPTURE_TESTS = '1'
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$source = Join-Path $PWD 'php-src'
$revision = & git -C $source rev-parse HEAD
if ($revision -ne $row.source_sha) { throw 'Source commit mismatch' }
foreach ($test in $row.tests) {
    if ($test -notmatch '^[a-zA-Z0-9_./-]+\.phpt$' -or $test.Contains('..') -or !(Test-Path (Join-Path $source $test))) { throw 'Invalid source test path' }
}
Push-Location $source
try {
    & $php -n run-tests.php -q --offline --show-diff -p $php -n -c "$bin/php-test.ini" @($row.tests) 2>&1 |
        Tee-Object -FilePath (Join-Path $reports 'source-recheck.log')
    $code = $LASTEXITCODE
} finally { Pop-Location }
if ($code -ne 0) { throw "Source recheck failed: $code" }
[xml] $xml = Get-Content $env:TEST_PHP_JUNIT -Raw
$cases = @($xml.SelectNodes('//testcase'))
if ($cases.Count -ne $row.tests.Count -or $xml.SelectNodes('//testcase/failure|//testcase/error|//testcase/skipped').Count) { throw 'Recheck failed, skipped, or omitted a case' }
@{passed=$true;run_id=$row.run_id;runtime=$row.runtime_name;sha256=$hash;source_sha=$revision;tests=$row.tests;arch=$row.arch;ts=$row.ts;opcache=$row.opcache;test_type=$row.test_type;gd_loaded=($gdLoaded -eq '1')} |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $reports 'summary.json')
