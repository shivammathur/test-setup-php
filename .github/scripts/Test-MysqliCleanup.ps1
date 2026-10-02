param([ValidateSet('original','terminate-before-close','delay-after-close')][string]$Cleanup)
$ErrorActionPreference = 'Stop'
$row = (Get-Content mysqli-manifest.json -Raw | ConvertFrom-Json).php[0]
$runtime = @($row.runtimeZips | Where-Object { $_.arch -eq 'x86' -and $_.ts -eq 'ts' })[0]
New-Item reports, unpacked, source-tests -ItemType Directory -Force | Out-Null
$workspace = (Get-Location).Path
$headers = @{ Authorization="Bearer $env:GH_TOKEN"; Accept='application/vnd.github+json' }
$api = 'https://api.github.com/repos/shivammathur/php-windows-builder'
$metadata = Invoke-RestMethod "$api/actions/artifacts/$($row.artifactId)" -Headers $headers
if ($metadata.workflow_run.id -ne $row.runId -or $metadata.expired) { throw 'Wrong PHP artifact' }
Invoke-WebRequest "$api/actions/artifacts/$($row.artifactId)/zip" -Headers $headers -OutFile merged.zip
if ((Get-FileHash merged.zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $row.artifactSha256) { throw 'Wrong merged archive hash' }
Expand-Archive merged.zip unpacked
$zip = Join-Path unpacked $runtime.name
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtime.sha256) { throw 'Wrong runtime archive hash' }
Expand-Archive $zip runtime
Invoke-WebRequest "https://api.github.com/repos/php/php-src/zipball/$($row.sourceCommit)" -Headers $headers -OutFile source.zip
Expand-Archive source.zip source-download
$source = @(Get-ChildItem source-download -Directory)
if ($source.Count -ne 1) { throw 'Unexpected pinned source layout' }
Get-ChildItem $source[0].FullName -Force | Move-Item -Destination source-tests
. ./builder/php/BuildPhp/private/Invoke-EditBin.ps1
Invoke-EditBin -Exe (Resolve-Path runtime/php.exe).Path -StackSize 8388608 -Arch x86
$phpExe = (Resolve-Path runtime/php.exe).Path
$test = 'ext/mysqli/tests/ghsa-r6x9-5r99-36j7-stmt-response-row-status.phpt'
$path = Join-Path source-tests $test
$original = (Get-Content $path -Raw).Replace("`r`n", "`n")
Copy-Item $path reports/original.phpt
if ($Cleanup -ne 'original') {
    $before = '$conn->close();' + "`n`n" + '$process->terminate();'
    $after = if ($Cleanup -eq 'terminate-before-close') { '$process->terminate();' + "`n`n" + '$conn->close();' } else { '$conn->close();' + "`n" + 'usleep(100000);' + "`n" + '$process->terminate();' }
    if (($original.Split($before).Count - 1) -ne 1) { throw 'Unexpected test cleanup sequence' }
    $original.Replace($before,$after) | Set-Content $path -NoNewline
}
Copy-Item $path reports/tested.phpt
foreach ($credential in @(Get-ChildItem Env: | Where-Object Name -Match '(?i)TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY')) { Remove-Item "Env:$($credential.Name)" }
$env:TEST_PHP_EXECUTABLE = $phpExe
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$env:SKIP_ONLINE_TESTS = '1'
$reports = @()
Push-Location source-tests
try {
    for ($i=1; $i -le 60; $i++) {
        $env:TEST_PHP_JUNIT = Join-Path $workspace "reports/result-$i.xml"
        & $phpExe -n run-tests.php -p $phpExe -n -d "extension_dir=$workspace\runtime\ext" -q --offline --show-diff $test 2>&1 | Tee-Object (Join-Path $workspace "reports/result-$i.log") | Out-Host
        if (!(Test-Path $env:TEST_PHP_JUNIT)) { throw 'Missing regression result' }
        [xml]$xml = Get-Content $env:TEST_PHP_JUNIT -Raw
        $reports += @{ iteration=$i; cases=@($xml.SelectNodes('//testcase')).Count; failures=@($xml.SelectNodes('//failure|//error')).Count; skipped=@($xml.SelectNodes('//skipped')).Count }
    }
} finally { Pop-Location }
@{ cleanup=$Cleanup; runId=$row.runId; sourceCommit=$row.sourceCommit; runtimeSha256=$runtime.sha256; reports=$reports } | ConvertTo-Json -Depth 10 | Set-Content reports/cleanup-results.json
if (@($reports | Where-Object { $_.cases -ne 1 -or $_.skipped -gt 0 }).Count) { throw 'Missing malformed-packet coverage' }
if ($Cleanup -eq 'terminate-before-close' -and @($reports | Where-Object failures -GT 0).Count) { throw 'Ordered cleanup did not resolve the failure' }
if ($Cleanup -eq 'delay-after-close' -and @($reports | Where-Object failures -GT 0).Count -eq 0) { throw 'The controlled cleanup interleaving did not reproduce the race' }
