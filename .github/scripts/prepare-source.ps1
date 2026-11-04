$ErrorActionPreference = 'Stop'
$diagnostics = Join-Path $env:RUNNER_TEMP 'setup-diagnostics'
New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null
$source = Join-Path $PSScriptRoot '..\source'
Copy-Item "$source\setup-mssql.ps1" '.github\scripts\windows\setup-mssql.ps1'
Copy-Item "$source\setup-windows-action.yml" '.github\actions\setup-windows\action.yml'
Get-FileHash '.github\scripts\windows\setup-mssql.ps1', '.github\actions\setup-windows\action.yml' |
    Select-Object Path, Hash | ConvertTo-Json | Out-File "$diagnostics\production-script-hashes.json"
$sizes = @{}
foreach ($letter in 'C', 'D') {
    $disk = Get-Partition -DriveLetter $letter | Get-Disk
    $sizes[$letter] = [int]$disk.PhysicalSectorSize
}
$sizes | ConvertTo-Json | Out-File "$diagnostics\physical-sectors.json"
if ($env:TEST_SQL_DRIVE -eq 'D') {
    if ($sizes.D -notin @(512, 4096)) { throw 'D: is incompatible with SQL Server on this runner' }
    $expected = 'D'
} else {
    $expected = @('C', 'D') | Where-Object { $sizes[$_] -in @(512, 4096) } | Select-Object -First 1
}
if (!$expected) { throw 'This runner has no compatible volume' }
"EXPECTED_SQL_DRIVE=$expected" | Out-File $env:GITHUB_ENV -Append
$actionPath = '.github\actions\setup-windows\action.yml'
$action = Get-Content $actionPath -Raw
$original = 'run: .github/scripts/windows/setup-mssql.ps1'
if (!$action.Contains($original)) { throw 'SQL Server action entry point changed' }
$action.Replace($original, 'run: .ci-harness/.github/scripts/invoke-setup-mssql.ps1') | Set-Content $actionPath
Write-Host "Requested $env:TEST_SQL_DRIVE installation; expected SQL drive: ${expected}:"
