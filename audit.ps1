param([Parameter(Mandatory)][ValidateSet('x64', 'x86', 'arm64')][string]$Arch)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$packages = @(Get-Content "$PSScriptRoot/packages.json" -Raw | ConvertFrom-Json | Where-Object arch -eq $Arch)
if ($packages.Count -ne 3) { throw "Expected three packages for $Arch" }
$results = New-Item -ItemType Directory -Path "$PSScriptRoot/results" -Force
$downloads = New-Item -ItemType Directory -Path "$PSScriptRoot/downloads" -Force
$records = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
function Invoke-Sqlite([string]$Exe, [string[]]$Arguments) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { $process.Kill($true); throw 'SQLite timed out' }
    $result = [ordered]@{ arguments = $Arguments; exit_code = $process.ExitCode; stdout = $stdout.GetAwaiter().GetResult(); stderr = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}
foreach ($package in $packages) {
    $record = [ordered]@{ name = $package.name; arch = $Arch; url = $package.url; status = 'failed' }
    try {
        $zip = Join-Path $downloads $package.name
        $headers = @{}
        if ($package.url.StartsWith('https://api.github.com/')) { $headers.Authorization = "Bearer $env:GH_TOKEN" }
        Invoke-WebRequest $package.url -Headers $headers -OutFile $zip -MaximumRetryCount 3 -RetryIntervalSec 3
        $record.zip_sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($record.zip_sha256 -ne $package.zip_sha256) { throw 'Published ZIP SHA256 mismatch' }
        $unpacked = Join-Path $downloads ([System.IO.Path]::GetFileNameWithoutExtension($package.name))
        Expand-Archive $zip -DestinationPath $unpacked -Force
        $exe = Join-Path $unpacked $package.exe_member
        $record.exe_sha256 = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($record.exe_sha256 -ne $package.exe_sha256) { throw 'Executable SHA256 mismatch' }
        $bom = Get-Content (Join-Path $unpacked 'share/sbom/sqlite3.cdx.json') -Raw | ConvertFrom-Json
        $vex = Get-Content (Join-Path $unpacked 'share/sbom/sqlite3.openvex.json') -Raw | ConvertFrom-Json
        $finding = @($bom.vulnerabilities | Where-Object id -eq 'CVE-2026-119586')
        if ($finding.Count -ne 1 -or $finding[0].analysis.state -ne 'not_affected' -or $finding[0].analysis.justification -ne 'code_not_present') { throw 'CycloneDX VEX mismatch' }
        $statement = @($vex.statements | Where-Object { $_.vulnerability.name -eq 'CVE-2026-119586' })
        if ($statement.Count -ne 1 -or $statement[0].status -ne 'not_affected' -or $statement[0].justification -ne 'vulnerable_code_not_present') { throw 'OpenVEX mismatch' }
        $record.vex = $finding[0].analysis
        $record.version = Invoke-Sqlite $exe @('-version')
        if ($record.version.exit_code -ne 0 -or -not $record.version.stdout.StartsWith($package.version + ' ')) { throw 'Executable version check failed' }
        $record.smoke = Invoke-Sqlite $exe @(':memory:', 'CREATE TABLE t(v); INSERT INTO t VALUES(42); SELECT v FROM t;')
        if ($record.smoke.exit_code -ne 0 -or $record.smoke.stdout.Trim() -ne '42') { throw 'Basic SQL check failed' }
        $record.options = Invoke-Sqlite $exe @(':memory:', 'PRAGMA compile_options;')
        if ($record.options.exit_code -ne 0 -or $record.options.stdout -match '(?m)^ENABLE_DBPAGE_VTAB\r?$') { throw 'DBPAGE unexpectedly enabled or options query failed' }
        $actualOptions = @($record.options.stdout -split "\r?\n" | Where-Object { $_ -and $_ -notlike 'COMPILER=*' } | Sort-Object)
        if (@(Compare-Object $actualOptions @($package.expected_compile_options)).Count) { throw 'Compile options changed from the published build' }
        $record.help = Invoke-Sqlite $exe @(':memory:', '.help')
        if ($record.help.exit_code -ne 0 -or $record.help.stdout -notmatch '(?m)^\.dump\s' -or $record.help.stdout -match '(?m)^\.recover\s') { throw 'Unexpected command help' }
        $record.recover = Invoke-Sqlite $exe @(':memory:', '.recover')
        if ($record.recover.exit_code -eq 0 -or $record.recover.stderr -notmatch 'unknown command or invalid arguments:.*recover') { throw 'Recovery command was not rejected as unavailable' }
        $record.status = 'passed'
        Write-Host "PASS $($package.name): .recover unavailable; DBPAGE disabled; SHA256 verified"
    } catch {
        $record.error = $_.Exception.Message
        $failures.Add("$($package.name): $($_.Exception.Message)")
        Write-Host "FAIL $($package.name): $($_.Exception.Message)"
    } finally {
        $records.Add($record)
        $records | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $results "audit-$Arch.json") -Encoding utf8NoBOM
    }
}
if ($failures.Count) { throw ($failures -join "`n") }
