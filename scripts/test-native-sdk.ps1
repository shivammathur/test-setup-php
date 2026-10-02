param(
    [Parameter(Mandatory)] [string] $SdkDirectory,
    [Parameter(Mandatory)] [string] $RuntimeDirectory,
    [Parameter(Mandatory)] [string] $ReportsDirectory,
    [switch] $ReportExistingStaticHeaderIssue
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'native-sdk.c'
$include = Join-Path $SdkDirectory 'include/apache2_4'
$library = Join-Path $SdkDirectory 'lib/apache2_4'
$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
$originalPath = $env:PATH
$env:PATH = "$(Join-Path $RuntimeDirectory 'bin');$env:PATH"
try {
    foreach ($mode in @('shared', 'static')) {
        $record = [ordered]@{ mode = $mode; status = 'failed' }
        try {
            $exe = Join-Path $ReportsDirectory "native-$mode.exe"
            $object = Join-Path $ReportsDirectory "native-$mode.obj"
            $defines = @(if ($mode -eq 'shared') { '/DSDK_SHARED=1' } else { '/DAPR_DECLARE_STATIC'; '/DAPU_DECLARE_STATIC'; '/DXML_STATIC' })
            $libraries = if ($mode -eq 'shared') { @('libhttpd.lib', 'libapr-1.lib', 'libaprutil-1.lib') } else {
                @('apr-1.lib', 'aprutil-1.lib', 'libexpatMD.lib', 'ws2_32.lib', 'mswsock.lib', 'advapi32.lib',
                  'kernel32.lib', 'rpcrt4.lib', 'shell32.lib', 'ole32.lib', 'uuid.lib', 'crypt32.lib', 'bcrypt.lib', 'secur32.lib')
            }
            & cl.exe /nologo /W4 /MD "/I$include" @defines "/Fo$object" $source /link "/LIBPATH:$library" @libraries "/OUT:$exe" 2>&1 |
                Tee-Object -FilePath (Join-Path $ReportsDirectory "native-$mode-build.log") | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Native $mode link failed: $LASTEXITCODE" }
            & $exe 2>&1 | Tee-Object -FilePath (Join-Path $ReportsDirectory "native-$mode-run.log") | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Native $mode runtime test failed: $LASTEXITCODE" }
            & dumpbin.exe /dependents $exe 2>&1 | Set-Content (Join-Path $ReportsDirectory "native-$mode-imports.log")
            if ($LASTEXITCODE -ne 0) { throw 'Could not inspect native test dependencies' }
            $imports = Get-Content (Join-Path $ReportsDirectory "native-$mode-imports.log") -Raw
            if ($mode -eq 'static' -and $imports -match '(?i)libapr(?:util)?-1\.dll|libexpat(?:MD)?\.dll') {
                throw 'Static test unexpectedly imports a dependency DLL'
            }
            $record.status = 'passed'
        } catch {
            $record.error = $_.Exception.Message
            $buildLog = Join-Path $ReportsDirectory "native-$mode-build.log"
            $log = if (Test-Path $buildLog) { Get-Content $buildLog -Raw } else { '' }
            $header = Get-Content (Join-Path $include 'apu.h') -Raw
            $knownStaticIssue = $mode -eq 'static' -and $ReportExistingStaticHeaderIssue -and
                $header -match '(?m)^#elif 0\s*$' -and $record.error -eq 'Native static link failed: 2' -and
                $log -match 'LNK1120: 6 unresolved externals' -and
                @([regex]::Matches($log, 'LNK2019: unresolved external symbol __imp_')).Count -eq 6
            if ($knownStaticIssue) {
                $record.known_issue = 'Packaged apu.h ignores APU_DECLARE_STATIC; reproduced in the Apache 2.4.68 baseline. Static APR-util SDK validation remains failed.'
                Write-Warning $record.known_issue
                "Static APR-util check: **FAILED** — $($record.known_issue)" | Add-Content $env:GITHUB_STEP_SUMMARY
            } else {
                $failures.Add("${mode}: $($_.Exception.Message)")
            }
        } finally { $results.Add([pscustomobject]$record) }
    }
} finally {
    $env:PATH = $originalPath
    $results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ReportsDirectory 'native-sdk-results.json')
}
if ($failures.Count) { throw ($failures -join "`n") }
