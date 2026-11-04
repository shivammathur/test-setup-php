$ErrorActionPreference = 'Stop'
$diagnostics = Join-Path $env:RUNNER_TEMP 'setup-diagnostics'
$buildDir = Join-Path $env:PHP_BUILD_OBJ_DIR $(if ($env:THREAD_SAFE -eq '1') { 'Release_TS' } else { 'Release' })
$php = Join-Path $buildDir 'php.exe'
$deps = @(Get-ChildItem $env:PHP_BUILD_CACHE_BASE_DIR -Directory -Filter 'deps-*')
if ($deps.Count -ne 1) { throw 'Cannot identify the PHP build dependency directory' }
$env:PATH = "$($deps[0].FullName)\bin;$buildDir;$env:PATH"
$iniArgs = @('-n', '-d', "extension_dir=$buildDir")
foreach ($extension in 'odbc', 'pdo_odbc', 'mysqli', 'pdo_mysql', 'pgsql', 'pdo_pgsql') {
    if (Test-Path "$buildDir\php_$extension.dll") { $iniArgs += @('-d', "extension=$extension") }
}
$expectedMachine = if ($env:PLATFORM -eq 'x64') { 0x8664 } else { 0x14c }
$binaries = foreach ($name in 'php.exe', 'php_odbc.dll', 'php_pdo_odbc.dll') {
    $file = Get-Item (Join-Path $buildDir $name)
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($file.FullName))
    try {
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadInt32() + 4
        $machine = $reader.ReadUInt16()
        if ($machine -ne $expectedMachine) { throw "Wrong PE architecture for $name" }
    } finally { $reader.Dispose() }
    [pscustomobject]@{ File = $file.Name; Length = $file.Length; Machine = $machine; SHA256 = (Get-FileHash $file.FullName).Hash; Version = $file.VersionInfo.FileVersion }
}
$binaries | ConvertTo-Json | Out-File "$diagnostics\built-binaries.json"
& $php @iniArgs --version | Tee-Object "$diagnostics\php-version.txt"
if ($LASTEXITCODE) { throw 'Built PHP does not start' }
& $php @iniArgs -m | Tee-Object "$diagnostics\php-modules.txt"
if ($LASTEXITCODE) { throw 'Built PHP modules failed to load' }
& mysql --host=127.0.0.1 --port=3306 --user=root '--password=Password12!' -e 'CREATE DATABASE IF NOT EXISTS test'
if ($LASTEXITCODE) { throw 'MySQL test database creation failed' }
$env:PGUSER = 'postgres'
$env:PGPASSWORD = 'Password12!'
& "$env:PGBIN\createdb.exe" -h 127.0.0.1 test
if ($LASTEXITCODE) { throw 'PostgreSQL test database creation failed' }
$env:ODBC_TEST_USER = 'sa'
$env:ODBC_TEST_PASS = 'Password12!'
$env:ODBC_TEST_DSN = 'Driver={ODBC Driver 17 for SQL Server};Server=(local)\SQLEXPRESS;Database=master;uid=sa;pwd=Password12!'
$env:PDOTEST_DSN = "odbc:$env:ODBC_TEST_DSN"
$env:PDOTEST_USER = 'sa'
$env:PDOTEST_PASS = 'Password12!'
& $php @iniArgs "$PSScriptRoot\php-database-smoke.php" | Tee-Object "$diagnostics\php-database-smoke.txt"
if ($LASTEXITCODE) { throw 'PHP database smoke tests failed' }
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$env:TEST_PHP_JUNIT = "$diagnostics\odbc-junit.xml"
$env:TEST_PHP_LOG_FORMAT = 'LEODS'
& $php @iniArgs run-tests.php @iniArgs -p $php -q --offline --no-progress --show-diff --set-timeout 120 -g FAIL,BORK,WARN ext/odbc/tests ext/pdo_odbc/tests 2>&1 |
    Tee-Object "$diagnostics\php-odbc-tests.txt"
$exitCode = $LASTEXITCODE
if ($exitCode) { throw "PHP ODBC/PDO_ODBC tests failed with exit $exitCode" }
exit 0
