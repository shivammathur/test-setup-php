$ErrorActionPreference = 'Stop'
$diagnosticStart = Get-Date
$root = $env:GITHUB_WORKSPACE
$manifest = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
$version = $env:TEST_PHP_VERSION
$lane = $manifest.lanes.$version
$targets = @($manifest.source_recheck_targets.$version)
$reports = Join-Path $root 'reports'
New-Item $reports -ItemType Directory -Force | Out-Null
$source = Join-Path $root 'php-source'
$helperRoot = Join-Path $root 'php-builder/php/BuildPhp'
$fixtures = @('sapi/cli/tests/php_cli_server_005.phpt','sapi/cli/tests/php_cli_server_014.phpt')
$fixtures += @(git -C $source ls-files 'sapi/cli/tests/*.txt')
foreach ($fixture in $fixtures) {
    $blob = git -C $source rev-parse "HEAD:$fixture"
    $actual = git -C $source hash-object --no-filters (Join-Path $source $fixture)
    if ($blob -ne $actual) { throw "Source fixture bytes changed during checkout: $fixture" }
}
. (Join-Path $helperRoot 'private/Set-PhpIniForTests.ps1')
. (Join-Path $helperRoot 'private/Invoke-CompatRunTestsPatch.ps1')
$patched = Invoke-CompatRunTestsPatch -Path (Join-Path $source 'run-tests.php') -PatchPath (Join-Path $helperRoot 'config/run-tests/run-tests-8.2-plus.patch')
if ($patched -isnot [bool] -or -not $patched) { throw 'Could not apply the same test runner compatibility patch as the source build' }
$env:SOURCE_RECHECK_DIAGNOSTICS = $reports
$cliHelper = Join-Path $source 'sapi/cli/tests/php_cli_server.inc'
$cliCode = [IO.File]::ReadAllText($cliHelper)
$failureBranch = 'if (empty($status[''running''])) {'
$diagnosticBranch = @'
if (empty($status['running'])) {
            file_put_contents(getenv('SOURCE_RECHECK_DIAGNOSTICS') . '/cli-startup-' . getmypid() . '.json', json_encode(['status' => $status, 'command' => $cmd, 'php' => PHP_VERSION, 'binary' => PHP_BINARY, 'bits' => PHP_INT_SIZE * 8, 'thread_safe' => PHP_ZTS, 'output' => file_get_contents($output_file)], JSON_PRETTY_PRINT));
'@
if (-not $cliCode.Contains($failureBranch)) { throw 'CLI startup diagnostic insertion point not found' }
[IO.File]::WriteAllText($cliHelper, $cliCode.Replace($failureBranch, $diagnosticBranch))
$records = [System.Collections.Generic.List[object]]::new()
$originalPath = $env:Path
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$env:SKIP_IO_CAPTURE_TESTS = '1'
Push-Location $source
try {
    foreach ($ts in @('ts','nts')) {
        $archive = @($lane.php_archives.PSObject.Properties | Where-Object { $_.Value.arch -eq $env:TEST_ARCH -and $_.Value.ts -eq $ts })
        if ($archive.Count -ne 1) { throw 'Expected one exact PHP runtime archive' }
        $zip = Join-Path $root "external/source-artifacts/$($archive[0].Name)"
        if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archive[0].Value.sha256) { throw 'PHP archive checksum mismatch' }
        $build = Join-Path $env:RUNNER_TEMP "source-recheck-$version-$env:TEST_ARCH-$ts"
        $phpRoot = Join-Path $build 'phpbin'
        Expand-Archive $zip -DestinationPath $phpRoot -Force
        $php = Join-Path $phpRoot 'php.exe'
        $env:Path = "$phpRoot;$originalPath"
        $env:TEST_PHP_EXECUTABLE = $php
        $env:TEST_PHP_CGI_EXECUTABLE = Join-Path $phpRoot 'php-cgi.exe'
        $env:TEST_PHPDBG_EXECUTABLE = Join-Path $phpRoot 'phpdbg.exe'
        foreach ($cache in @('opcache','nocache')) {
            Set-PhpIniForTests -BuildDirectory $build -Arch $env:TEST_ARCH -Opcache $cache -TestType php
            $invocations = @()
            foreach ($mode in @('serial','parallel')) {
                foreach ($repeat in 1..3) { $invocations += [pscustomobject]@{kind='focused';mode=$mode;repeat=$repeat;paths=$targets} }
            }
            $invocations += [pscustomobject]@{kind='sapi-suite';mode='parallel';repeat=1;paths=@('sapi/cli/tests','sapi/cgi/tests')}
            foreach ($invocation in $invocations) {
                $label = "$ts-$cache-$($invocation.kind)-$($invocation.mode)-$($invocation.repeat)"
                $env:TEST_PHP_JUNIT = Join-Path $reports "$label.xml"
                $parameters = @('-n','-d','open_basedir=','-d','output_buffering=0','run-tests.php','-p',$php,'-n','-c',"$phpRoot/php-test.ini",'--no-progress','-g','FAIL,BORK,WARN,LEAK','-q','--offline','--show-diff','--set-timeout','120')
                if ($invocation.mode -eq 'parallel') { $parameters += '-j6' }
                $parameters += $invocation.paths
                & $php @parameters 2>&1 | Tee-Object -FilePath (Join-Path $reports "$label.log") | Out-Host
                $code = $LASTEXITCODE
                if (-not (Test-Path $env:TEST_PHP_JUNIT)) { throw "Missing JUnit report $label" }
                [xml]$junit = Get-Content $env:TEST_PHP_JUNIT -Raw
                $cases = @($junit.SelectNodes('//testcase'))
                $failures = @($junit.SelectNodes('//failure|//error'))
                $skipped = @($junit.SelectNodes('//skipped'))
                $passed = $code -eq 0 -and $cases.Count -gt 0 -and $failures.Count -eq 0
                if ($invocation.kind -eq 'focused') { $passed = $passed -and $cases.Count -eq $targets.Count -and $skipped.Count -eq 0 }
                $records.Add([pscustomobject]@{php=$version;arch=$env:TEST_ARCH;ts=$ts;opcache=$cache;kind=$invocation.kind;mode=$invocation.mode;repeat=$invocation.repeat;tests=$cases.Count;failures=$failures.Count;skipped=$skipped.Count;exit_code=$code;passed=$passed;archive=$archive[0].Name;sha256=$archive[0].Value.sha256;source_sha=$lane.php_source_sha})
            }
        }
    }
} finally {
    Pop-Location
    $events = @(Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$diagnosticStart;Id=@(1000,1001)} -ErrorAction SilentlyContinue | Select-Object TimeCreated,Id,ProviderName,Message)
    ConvertTo-Json -InputObject $events -Depth 5 | Set-Content (Join-Path $reports 'windows-error-events.json')
    $runtime = @()
    foreach ($folder in @('System32','SysWOW64')) {
        foreach ($name in @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','ucrtbase.dll')) {
            $dll = Join-Path $env:WINDIR "$folder/$name"
            if (Test-Path $dll) { $runtime += [pscustomobject]@{path=$dll;version=(Get-Item $dll).VersionInfo.FileVersion;sha256=(Get-FileHash $dll -Algorithm SHA256).Hash} }
        }
    }
    $runtime | ConvertTo-Json | Set-Content (Join-Path $reports 'runtime-inventory.json')
    $records | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $reports 'results.json')
    Get-ChildItem $source -Recurse -File | Where-Object Extension -in @('.diff','.out','.exp','.log') | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($source, $_.FullName)
        $destination = Join-Path $reports "diagnostics/$relative"
        New-Item (Split-Path $destination) -ItemType Directory -Force | Out-Null
        Copy-Item $_.FullName $destination -Force
    }
}
if ($records.Count -ne 28 -or @($records | Where-Object { -not $_.passed }).Count) { throw 'Source reproduction has failed or missing checks' }
