param([ValidateSet('ts','nts')][string]$Ts)
$ErrorActionPreference = 'Stop'
$row = (Get-Content ssl-write-manifest.json -Raw | ConvertFrom-Json).psk
$row | Add-Member -NotePropertyName runner -NotePropertyValue (@($row.sources | Where-Object name -EQ 'run-tests.php')[0]) -Force
$row | Add-Member -NotePropertyName test -NotePropertyValue (@($row.sources | Where-Object name -EQ 'ServerClientTestCase.inc')[0])
$runtime = @($row.runtimeZips | Where-Object { $_.arch -eq 'x86' -and $_.ts -eq $Ts })[0]
New-Item reports, unpacked, minimal, cases -ItemType Directory -Force | Out-Null
$workspace = (Get-Location).Path
Start-Transcript reports/transcript.txt
$headers = @{Authorization="Bearer $env:GH_TOKEN"; Accept='application/vnd.github+json'}
$api = 'https://api.github.com/repos/shivammathur/php-windows-builder'
$artifact = Invoke-RestMethod "$api/actions/artifacts/$($row.artifactId)" -Headers $headers
if ($artifact.expired -or $artifact.workflow_run.id -ne $row.runId -or $artifact.name -ne 'artifacts') { throw 'Artifact identity changed' }
Invoke-WebRequest "$api/actions/artifacts/$($row.artifactId)/zip" -Headers $headers -OutFile merged.zip
if ((Get-FileHash merged.zip).Hash.ToLowerInvariant() -ne $row.artifactSha256) { throw 'Artifact digest changed' }
Expand-Archive merged.zip unpacked
$zip = Join-Path unpacked $runtime.name
if ((Get-FileHash $zip).Hash.ToLowerInvariant() -ne $runtime.sha256) { throw 'Runtime digest changed' }
Expand-Archive $zip runtime
$coreDll = if ($Ts -eq 'ts') { 'php8ts.dll' } else { 'php8.dll' }
Copy-Item runtime/php.exe, "runtime/$coreDll" minimal
@('opcache.enable=1','opcache.enable_cli=1') | Set-Content minimal/php.ini
$files = @(Get-ChildItem minimal -File | ForEach-Object { @{name=$_.Name; sha256=(Get-FileHash $_.FullName).Hash.ToLowerInvariant()} })
foreach ($source in @(@{spec=$row.runner; path='run-tests.php'}, @{spec=$row.test; path='cases/ServerClientTestCase.inc'})) {
    Invoke-WebRequest $source.spec.url -OutFile $source.path
    if ((Get-FileHash $source.path).Hash.ToLowerInvariant() -ne $source.spec.sha256) { throw 'Pinned source hash mismatch' }
}
. ./builder/php/BuildPhp/private/Invoke-CompatRunTestsPatch.ps1
$patch = (Resolve-Path builder/php/BuildPhp/config/run-tests/run-tests-8.2-plus.patch).Path
if (!(Invoke-CompatRunTestsPatch -Path (Resolve-Path run-tests.php).Path -PatchPath $patch)) { throw 'Could not reproduce the source CI worker setup' }
Get-FileHash run-tests.php, $patch | ConvertTo-Json | Set-Content reports/runner-hashes.json
$test = @'
--TEST--
Plain TCP server startup through the unchanged SSL test helper
--FILE--
<?php
$serverCode = <<<'CODE'
    $server = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
    phpt_notify_server_start($server);
    $client = stream_socket_accept($server, 30);
    fwrite($client, "tcp-ok");
    fclose($client);
CODE;
$clientCode = <<<'CODE'
    $client = stream_socket_client('tcp://{{ ADDR }}', $errno, $errstr, 30);
    var_dump(fread($client, 1024));
    fclose($client);
CODE;
include __DIR__ . '/ServerClientTestCase.inc';
ServerClientTestCase::getInstance()->run($clientCode, $serverCode);
?>
--EXPECT--
string(6) "tcp-ok"
'@
for ($i=1; $i -le 1000; $i++) { [IO.File]::WriteAllText((Join-Path $workspace "cases/server-$i.phpt"), $test) }
$exe = (Resolve-Path minimal/php.exe).Path
$env:PHPRC = (Resolve-Path minimal).Path
$env:PHP_INI_SCAN_DIR = $env:PHPRC
$env:TEST_PHP_EXECUTABLE = $exe
Remove-Item Env:TEST_PHP_ARGS -ErrorAction SilentlyContinue
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$env:SKIP_ONLINE_TESTS = '1'
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
foreach ($credential in @(Get-ChildItem Env: | Where-Object Name -Match '(?i)TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY')) { Remove-Item "Env:$($credential.Name)" }
$loaded = & $exe -r 'echo json_encode(get_loaded_extensions());'
if ($LASTEXITCODE -ne 0 -or 'openssl' -in ($loaded | ConvertFrom-Json)) { throw 'Minimal core isolation failed' }
$loaded | Set-Content reports/loaded-extensions.json
$env:TEST_PHP_JUNIT = Join-Path $workspace 'reports/results.xml'
& $exe -n run-tests.php -p $exe -n -c (Join-Path $env:PHPRC 'php.ini') -j8 -q --offline --show-diff cases 2>&1 | Tee-Object reports/tests.log | Out-Host
$exitCode = $LASTEXITCODE
[xml]$xml = Get-Content reports/results.xml -Raw
$result = @{runId=$row.runId; sourceCommit=$row.sourceCommit; runtime=$runtime.name; runtimeSha256=$runtime.sha256; ts=$Ts; files=$files; cases=@($xml.SelectNodes('//testcase')).Count; failures=@($xml.SelectNodes('//failure|//error')).Count; skipped=@($xml.SelectNodes('//skipped')).Count; exit=$exitCode}
$result | ConvertTo-Json -Depth 10 | Set-Content reports/summary.json
Copy-Item cases/ServerClientTestCase.inc reports
[IO.File]::WriteAllText((Join-Path $workspace "reports/plain-tcp-control.phpt"), $test)
Get-ChildItem cases -File | Where-Object Extension -In '.diff','.out','.exp','.log' | Copy-Item -Destination reports
Stop-Transcript
if ($result.cases -ne 1000 -or $result.skipped -ne 0 -or $result.failures -ne 0 -or $exitCode -ne 0) { throw 'Inspect retained server-start diagnostic evidence' }
