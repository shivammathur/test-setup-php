param([switch]$Before)
$ErrorActionPreference = 'Continue'
$diagnostics = Join-Path $env:RUNNER_TEMP 'setup-diagnostics'
New-Item -ItemType Directory -Path $diagnostics -Force | Out-Null
if ($Before) {
    Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber | Format-List | Out-File "$diagnostics\os.txt"
    Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors | Format-List | Out-File "$diagnostics\cpu.txt"
    Get-CimInstance Win32_ComputerSystem | Select-Object Model, TotalPhysicalMemory, NumberOfLogicalProcessors | Format-List | Out-File "$diagnostics\computer.txt"
    "ImageOS=$env:ImageOS`nImageVersion=$env:ImageVersion`nRunnerName=$env:RUNNER_NAME" | Out-File "$diagnostics\runner.txt"
    fsutil fsinfo sectorinfo C: 2>&1 | Tee-Object "$diagnostics\sectors-c.txt"
    fsutil fsinfo sectorinfo D: 2>&1 | Tee-Object "$diagnostics\sectors-d.txt"
    Get-Service | Where-Object Name -Match 'SQL|MySQL' | Format-List Name, Status, StartType | Out-File "$diagnostics\services-before.txt"
    exit 0
}
$sqlRoot = 'C:\Program Files\Microsoft SQL Server'
$full = $env:CAPTURE_FULL -eq 'true'
$paths = @("$sqlRoot\160\Setup Bootstrap\Log", "$sqlRoot\MSSQL16.SQLEXPRESS\MSSQL\Log")
foreach ($path in $paths) {
    if (!(Test-Path $path)) { continue }
    Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { ($full -and $_.Extension -in '.txt', '.log', '.ini', '.xml', '.mdmp') -or $_.Name -like 'Summary*' -or $_.Name -match '^ERRORLOG(\.[0-9]+)?$' -or $_.Name -like 'SQLServer_ERRORLOG*' } |
        ForEach-Object {
            $target = Join-Path "$diagnostics\sql" $_.FullName.Substring($sqlRoot.Length + 1)
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
            if ($full -and ($_.Name -eq 'Summary.txt' -or $_.Name -match '^ERRORLOG')) {
                Write-Host "::group::$($_.FullName)"
                Get-Content -LiteralPath $_.FullName -Tail 250
                Write-Host '::endgroup::'
            }
        }
}
Copy-Item 'C:\ProgramData\chocolatey\logs\chocolatey.log' "$diagnostics\chocolatey.log" -ErrorAction SilentlyContinue
Get-Service | Where-Object Name -Match 'SQL|MySQL' | Format-List Name, Status, StartType | Out-File "$diagnostics\services-after.txt"
if ($full) {
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddHours(-1) } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'SQL|MySQL|MsiInstaller|Application Error|Windows Error Reporting' } |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message | Format-List | Out-File "$diagnostics\application-events.txt"
    Get-ChildItem 'C:\ProgramData\MySQL', 'C:\Program Files\MySQL' -Filter '*.err' -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $diagnostics $_.Name) -Force }
}
exit 0
