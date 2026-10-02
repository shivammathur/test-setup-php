$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$row = Get-Content cgi-diagnostics.json -Raw | ConvertFrom-Json
$runtime = @($row.runtimes | Where-Object { $_.arch -eq 'x86' -and $_.ts -eq 'ts' })[0]
New-Item reports, unpacked, minimal -ItemType Directory -Force | Out-Null
$workspace = (Get-Location).Path
$headers = @{Authorization="Bearer $env:GH_TOKEN"; Accept='application/vnd.github+json'}
$api = 'https://api.github.com/repos/shivammathur/php-windows-builder'
$artifact = Invoke-RestMethod "$api/actions/artifacts/$($row.artifactId)" -Headers $headers
if ($artifact.workflow_run.id -ne $row.run -or $artifact.expired) { throw 'Unexpected artifact identity' }
Invoke-WebRequest "$api/actions/artifacts/$($row.artifactId)/zip" -Headers $headers -OutFile merged.zip
if ((Get-FileHash merged.zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $row.sha256) { throw 'Merged artifact mismatch' }
Expand-Archive merged.zip unpacked
$zip = Join-Path unpacked $runtime.name
if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtime.sha256) { throw 'Runtime ZIP mismatch' }
Expand-Archive $zip runtime
foreach ($name in @('php.exe','php-cgi.exe','php8ts.dll')) {
    Copy-Item "runtime/$name" minimal
    dumpbin /nologo /dependents "minimal/$name" | Set-Content "reports/$name-imports.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Import inspection failed' }
}
Get-ChildItem minimal -File | Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content reports/minimal-hashes.json
if ((git -C php-src rev-parse HEAD) -ne $row.source_sha) { throw 'Source mismatch' }
. ./builder/php/BuildPhp/private/Invoke-CompatRunTestsPatch.ps1
$patch = (Resolve-Path builder/php/BuildPhp/config/run-tests/run-tests-8.2-plus.patch).Path
if (!(Invoke-CompatRunTestsPatch -Path (Resolve-Path php-src/run-tests.php).Path -PatchPath $patch)) { throw 'Cannot apply the CI runner compatibility patch' }
$php = (Resolve-Path minimal/php.exe).Path
$env:TEST_PHP_EXECUTABLE = $php
$env:TEST_PHP_CGI_EXECUTABLE = (Resolve-Path minimal/php-cgi.exe).Path
$env:PHP_INI_SCAN_DIR = ''
$env:PHPRC = (Resolve-Path minimal).Path
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
# Restrict resolution to the isolated core and Windows runtime libraries.
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
foreach ($credential in @(Get-ChildItem Env: | Where-Object Name -Match '(?i)TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY')) { Remove-Item "Env:$($credential.Name)" }
$extensions = & $php -n -r 'echo json_encode(get_loaded_extensions());'
if ($LASTEXITCODE -ne 0) { throw 'Isolated core startup failed' }
$extensions | Set-Content reports/extensions.json
if ('gd' -in ($extensions | ConvertFrom-Json)) { throw 'GD must be absent' }
Push-Location php-src
$results = @()
try {
    foreach ($mode in @('serial','parallel')) {
        $count = if ($mode -eq 'serial') {20} else {120}
        $tests = @(for ($i=0; $i -lt $count; $i++) {
            $path = "sapi/cgi/tests/png-diagnostic-$i.phpt"
            Copy-Item sapi/cgi/tests/011.phpt $path -Force
            $path
        })
        $env:TEST_PHP_JUNIT = Join-Path $workspace "reports/$mode.xml"
        $arguments = @('-n','run-tests.php','-p',$php,'-n','-q','--offline','--show-diff','-g','FAIL,BORK,WARN')
        if ($mode -eq 'parallel') { $arguments += '-j6' }
        & $php @arguments @tests 2>&1 | Tee-Object (Join-Path $workspace "reports/$mode.log")
        $exitCode = $LASTEXITCODE
        [xml]$xml = Get-Content $env:TEST_PHP_JUNIT -Raw
        $results += @{mode=$mode; exit=$exitCode; cases=@($xml.SelectNodes('//testcase')).Count; failures=@($xml.SelectNodes('//failure|//error')).Count; skipped=@($xml.SelectNodes('//skipped')).Count}
        $results | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $workspace reports/results.json)
    }
} finally { Pop-Location }
if (@($results | Where-Object { $_.cases -eq 0 -or $_.skipped -gt 0 }).Count) { throw 'Incomplete diagnostic coverage' }
# A reproduced failure is retained as diagnostic evidence, not converted to a pass.
$results | ConvertTo-Json
