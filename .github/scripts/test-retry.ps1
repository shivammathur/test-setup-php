param([string]$Scenario = 'fixtures')
$ErrorActionPreference = 'Stop'
$retryScript = Join-Path $PSScriptRoot 'retry-choco.ps1'
$global:RealChoco = if ($Scenario -ne 'fixtures') { (Get-Command choco.exe).Source } else { $null }
$cases = if ($Scenario -eq 'fixtures') {
    @(
        @{ Name = 'success'; Calls = 1; Exit = 0 },
        @{ Name = 'feed-recovery'; Calls = 2; Exit = 0 },
        @{ Name = 'download-recovery'; Calls = 2; Exit = 0 },
        @{ Name = 'download-exhausted'; Calls = 3; Exit = 1 },
        @{ Name = 'installer-failure'; Calls = 1; Exit = 1 },
        @{ Name = 'mixed-failure'; Calls = 1; Exit = 1 }
    )
} else {
    @(@{ Name = $Scenario; Calls = 2; Exit = 0 })
}
if ($Scenario -eq 'fixtures') {
    function global:Start-Sleep { param([int]$Seconds) Write-Host "Test sleep: $Seconds seconds" }
}
$results = @()
foreach ($case in $cases) {
    $global:RetryCase = $case.Name
    $global:RetryCalls = 0
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
                Write-Output 'ERROR: Unable to read data from the transport connection: An existing connection was forcibly closed by the remote host.'
                $global:LASTEXITCODE = 1
            }
            return
        }
        if ($global:RetryCase -in 'installer-failure', 'mixed-failure') {
            if ($global:RetryCase -eq 'mixed-failure') { Write-Output 'Warning: The underlying connection was closed.' }
            Write-Output 'Installing sql-server-express...'
            Write-Output "ERROR: Running setup.exe was not successful. Exit code was '-2061893607'."
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
    if ($actualExit -ne $case.Exit -or $global:RetryCalls -ne $case.Calls) {
        throw "$($case.Name): exit $actualExit (expected $($case.Exit)), calls $global:RetryCalls (expected $($case.Calls))"
    }
    $results += [pscustomobject]@{ Scenario = $case.Name; Calls = $global:RetryCalls; ExitCode = $actualExit; Passed = $true }
    Write-Host "PASS: $($case.Name), calls=$global:RetryCalls, exit=$actualExit"
}
if ($env:RUNNER_TEMP) {
    $results | ConvertTo-Json | Out-File (Join-Path $env:RUNNER_TEMP 'setup-diagnostics\retry-results.json')
}
Remove-Item Function:\choco
if ($Scenario -eq 'fixtures') { Remove-Item Function:\Start-Sleep }
exit 0
