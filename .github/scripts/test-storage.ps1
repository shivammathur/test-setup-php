$ErrorActionPreference = 'Stop'
$setupScript = Join-Path $PSScriptRoot 'windows\setup-mssql.ps1'
$cases = @(
    @{ Name = 'prefer-c'; C = 4096; D = 4096; Expected = 'C' },
    @{ Name = 'fallback-d'; C = 8192; D = 4096; Expected = 'D' },
    @{ Name = 'c-512'; C = 512; D = 8192; Expected = 'C' },
    @{ Name = 'd-512'; C = 8192; D = 512; Expected = 'D' },
    @{ Name = 'missing-d'; C = 4096; Expected = 'C' },
    @{ Name = 'missing-c'; D = 4096; Expected = 'D' },
    @{ Name = 'unreadable-c'; C = 'error'; D = 4096; Expected = 'D' },
    @{ Name = 'unknown-c'; C = 0; D = 4096; Expected = 'D' },
    @{ Name = 'incompatible'; C = 8192; D = 16384 },
    @{ Name = 'missing-both' },
    @{ Name = 'unreadable-both'; C = 'error'; D = 'error' },
    @{ Name = 'unknown-both'; C = 0; D = 0 }
)
function global:Test-Path {
    param([string]$Path)
    if ($Path -match '^([CD]):\\$') {
        return $global:StorageCase.ContainsKey($Matches[1])
    }
    Microsoft.PowerShell.Management\Test-Path -Path $Path
}
function global:Get-Partition {
    param([string]$DriveLetter)
    [pscustomobject]@{ DriveLetter = $DriveLetter }
}
function global:Get-Disk {
    param([Parameter(ValueFromPipeline)]$Partition)
    process {
        $size = $global:StorageCase[$Partition.DriveLetter]
        if ($size -eq 'error') { throw 'Fixture storage query failure' }
        [pscustomobject]@{ PhysicalSectorSize = $size }
    }
}
function global:choco {
    $global:StorageCalls++
    $global:StorageArguments = @($args)
    $global:LASTEXITCODE = 0
}
function global:New-ItemProperty { throw 'Registry writes are forbidden in this test' }
function global:Set-ItemProperty { throw 'Registry writes are forbidden in this test' }
$results = @()
try {
    foreach ($case in $cases) {
        $global:StorageCase = $case
        $global:StorageCalls = 0
        $global:StorageArguments = @()
        $failure = $null
        try { & $setupScript } catch { $failure = $_ }
        if ($case.Expected) {
            $installDir = "$($case.Expected):\SQLServer"
            $expectedArguments = "--install-arguments=/SECURITYMODE=SQL /SAPWD=Password12! /INSTANCEDIR=$installDir /INSTALLSQLDATADIR=$installDir"
            if ($failure -or $global:StorageCalls -ne 1 -or $global:StorageArguments -notcontains $expectedArguments) {
                throw "Failed $($case.Name): calls=$global:StorageCalls, args=$global:StorageArguments, error=$failure"
            }
        } elseif (!$failure -or $global:StorageCalls -ne 0) {
            throw "Failed $($case.Name): incompatible storage must stop before Chocolatey"
        }
        $results += [pscustomobject]@{ Scenario = $case.Name; SelectedDrive = $case.Expected; Calls = $global:StorageCalls; Passed = $true }
        Write-Host "PASS: $($case.Name), selected=$($case.Expected), choco calls=$global:StorageCalls"
    }
    if ($env:RUNNER_TEMP) {
        $results | ConvertTo-Json | Out-File (Join-Path $env:RUNNER_TEMP 'setup-diagnostics\storage-results.json')
    }
} finally {
    'Test-Path', 'Get-Partition', 'Get-Disk', 'choco', 'New-ItemProperty', 'Set-ItemProperty' |
        ForEach-Object { Remove-Item "Function:\$_" }
}
exit 0
