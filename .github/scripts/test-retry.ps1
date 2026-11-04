param([string]$Scenario = 'fixtures')
$ErrorActionPreference = 'Stop'
$retryScript = Join-Path $PSScriptRoot 'windows\setup-mssql.ps1'
$global:RealChoco = if ($Scenario -ne 'fixtures') { (Get-Command choco.exe).Source } else { $null }
$cases = if ($Scenario -eq 'fixtures') {
    @(
        @{ Name = 'success'; Calls = 1; Exit = 0 },
        @{ Name = 'feed-recovery'; Calls = 2; Exit = 0 },
        @{ Name = 'download-recovery'; Calls = 2; Exit = 0 },
        @{ Name = 'eof-recovery'; Calls = 2; Exit = 0 },
        @{ Name = 'generic-preinstall-recovery'; Calls = 2; Exit = 0 },
        @{ Name = 'download-exhausted'; Calls = 3; Exit = 404 },
        @{ Name = 'installer-failure'; Calls = 1; Exit = 1 },
        @{ Name = 'other-error'; Calls = 1; Exit = 5 }
    )
} else {
    @(@{ Name = $Scenario; Calls = 2; Exit = 0 })
}
if ($Scenario -eq 'fixtures') {
    function global:Get-Partition {
        param([string]$DriveLetter)
        [pscustomobject]@{ DriveLetter = $DriveLetter }
    }
    function global:Get-Disk {
        param([Parameter(ValueFromPipeline)]$Partition)
        process { [pscustomobject]@{ PhysicalSectorSize = if ($Partition.DriveLetter -eq 'C') { 8192 } else { 4096 } } }
    }
    function global:Start-Sleep { param([int]$Seconds) $global:RetryDelays += $Seconds; Write-Host "Test sleep: $Seconds seconds" }
}
$results = @()
foreach ($case in $cases) {
    $global:RetryCase = $case.Name
    $global:RetryCalls = 0
    $global:RetryDelays = @()
    $global:FixtureSqlDirectory = $false
    function global:choco {
        $global:RetryCalls++
        if ($global:RetryCase -eq 'feed-recovery' -and $global:RetryCalls -eq 1) {
            if ($global:RealChoco) {
                & $global:RealChoco @args '--source=http://127.0.0.1:9/api/v2/'
                $global:LASTEXITCODE = $LASTEXITCODE
            } else {
                Write-Output "Unable to connect to source 'https://community.chocolatey.org/api/v2/': Response status code does not indicate success: 499 (<none>)."
                $global:LASTEXITCODE = 1
            }
            return
        }
        if ($global:RetryCase -eq 'generic-preinstall-recovery' -and $global:RetryCalls -eq 1) {
            $global:LASTEXITCODE = -1
            return
        }
        if ($global:RetryCase -eq 'other-error') {
            $global:LASTEXITCODE = 5
            return
        }
        if ($global:RetryCase -eq 'eof-recovery' -and $global:RetryCalls -eq 1) {
            Write-Output 'ERROR: Received an unexpected EOF or 0 bytes from the transport stream.'
            $global:LASTEXITCODE = 404
            return
        }
        if (($global:RetryCase -eq 'download-recovery' -and $global:RetryCalls -eq 1) -or $global:RetryCase -eq 'download-exhausted') {
            if ($global:RealChoco) {
                $diagnostics = Join-Path $env:RUNNER_TEMP 'setup-diagnostics'
                $proxyScript = Join-Path $PSScriptRoot 'reset-download-proxy.py'
                $proxy = Start-Process python -ArgumentList @('-u', $proxyScript, '8765') -PassThru -RedirectStandardOutput "$diagnostics\proxy-output.log" -RedirectStandardError "$diagnostics\proxy-errors.log"
                try {
                    Start-Sleep -Seconds 2
                    & $global:RealChoco @args '--proxy=http://127.0.0.1:8765'
                    $global:LASTEXITCODE = $LASTEXITCODE
                    Get-ChildItem "$env:TEMP\chocolatey\sql-server-express" -Recurse -Filter SQLEXPR.exe -ErrorAction SilentlyContinue |
                        Select-Object FullName, Length | ConvertTo-Json | Out-File "$diagnostics\partial-download.json"
                } finally {
                    Stop-Process -Id $proxy.Id -Force -ErrorAction SilentlyContinue
                }
                if ((Get-Content "$diagnostics\proxy-output.log" -Raw) -notmatch 'RESET download.microsoft.com') {
                    throw 'The proxy did not interrupt an actual Microsoft installer transfer'
                }
            } else {
                Write-Output 'Transfer failed.'
                $global:LASTEXITCODE = 404
            }
            return
        }
        if ($global:RetryCase -eq 'installer-failure') {
            if (Test-Path 'D:\SQLServer') { throw 'Fixture refuses to replace an existing SQL instance directory' }
            New-Item -ItemType Directory -Path 'D:\SQLServer' | Out-Null
            $global:FixtureSqlDirectory = $true
            $global:LASTEXITCODE = 1
            return
        }
        if ($global:RealChoco) {
            & $global:RealChoco @args
            $global:LASTEXITCODE = $LASTEXITCODE
        } else {
            Write-Output 'Chocolatey installed 1/1 packages.'
            $global:LASTEXITCODE = 0
        }
    }
    & $retryScript
    $actualExit = $LASTEXITCODE
    if ($global:FixtureSqlDirectory) { Remove-Item -LiteralPath 'D:\SQLServer' }
    if ($actualExit -ne $case.Exit -or $global:RetryCalls -ne $case.Calls) {
        throw "$($case.Name): exit $actualExit (expected $($case.Exit)), calls $global:RetryCalls (expected $($case.Calls))"
    }
    if ($Scenario -eq 'fixtures') {
        $expectedDelays = switch ($case.Calls) { 1 { '' }; 2 { '3' }; 3 { '3,6' } }
        if (($global:RetryDelays -join ',') -ne $expectedDelays) { throw "Incorrect backoff for $($case.Name): $global:RetryDelays" }
    }
    $results += [pscustomobject]@{ Scenario = $case.Name; Calls = $global:RetryCalls; ExitCode = $actualExit; Delays = @($global:RetryDelays); Passed = $true }
    Write-Host "PASS: $($case.Name), calls=$global:RetryCalls, exit=$actualExit"
}
if ($env:RUNNER_TEMP) {
    $results | ConvertTo-Json | Out-File (Join-Path $env:RUNNER_TEMP 'setup-diagnostics\retry-results.json')
}
Remove-Item Function:\choco
if ($Scenario -eq 'fixtures') { Remove-Item Function:\Start-Sleep; Remove-Item Function:\Get-Partition; Remove-Item Function:\Get-Disk }
exit 0
