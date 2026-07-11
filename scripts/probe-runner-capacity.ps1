param(
    [Parameter(Mandatory = $true)]
    [string] $PhpDirectory,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,
    [Parameter(Mandatory = $true)]
    [int] $Replica
)

$ErrorActionPreference = 'Stop'
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$rawDirectory = Join-Path $OutputDirectory 'raw'
New-Item -Path $rawDirectory -ItemType Directory -Force | Out-Null

$php = Join-Path $PhpDirectory 'php.exe'
$ini = Join-Path $PhpDirectory 'php.ini'
$activationScript = (Resolve-Path (Join-Path $PSScriptRoot '..\tests\com-activation.php')).Path
$loadScript = (Resolve-Path (Join-Path $PSScriptRoot 'generate-runner-load.ps1')).Path
$nativeScript = (Resolve-Path (Join-Path $PSScriptRoot 'native-com-probe.ps1')).Path
$pwsh = (Get-Command pwsh.exe).Source
$logicalProcessors = [Environment]::ProcessorCount
$results = [System.Collections.Generic.List[object]]::new()

function Get-RunnerSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $processes = @(Get-Process -ErrorAction SilentlyContinue)
    $processor = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        CpuPercent = if ($null -eq $processor) { $null } else { $processor.PercentProcessorTime }
        AvailableMegabytes = [math]::Round($os.FreePhysicalMemory / 1024, 1)
        ProcessCount = $processes.Count
        ThreadCount = ($processes | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
        HandleCount = ($processes | Measure-Object HandleCount -Sum).Sum
        IeProcessCount = @(Get-Process -Name iexplore -ErrorAction SilentlyContinue).Count
        IeLowUtilCount = @(Get-Process -Name ielowutil -ErrorAction SilentlyContinue).Count
    }
}

function Invoke-PhpActivation {
    param(
        [string] $Phase,
        [bool] $CallMethod
    )

    $method = if ($CallMethod) { '1' } else { '0' }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & $php -c $ini $activationScript $Phase $method 2>&1
    $exitCode = $LASTEXITCODE
    $timer.Stop()
    $jsonLine = @($output | ForEach-Object { "$_" } | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    if ($jsonLine.Count -eq 0) {
        return [pscustomobject]@{
            success = $false
            code = $exitCode
            hex = 'NO_JSON'
            message = ($output -join "`n")
            create_ms = $null
            total_ms = $timer.Elapsed.TotalMilliseconds
            process_ms = $timer.Elapsed.TotalMilliseconds
        }
    }

    $parsed = $jsonLine[0] | ConvertFrom-Json
    $parsed | Add-Member -NotePropertyName process_ms -NotePropertyValue $timer.Elapsed.TotalMilliseconds
    return $parsed
}

function Start-RunnerLoad {
    param(
        [ValidateSet('Cpu', 'Process')]
        [string] $Mode,
        [int] $Count
    )

    if ($Count -le 0) {
        return @()
    }

    $processes = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $processes += Start-Process -FilePath $pwsh `
                                    -ArgumentList '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $loadScript, '-Mode', $Mode, '-Seconds', '600' `
                                    -WindowStyle Hidden `
                                    -PassThru
    }
    Start-Sleep -Seconds 2
    return $processes
}

function Stop-RunnerLoad {
    param([object[]] $Processes)
    foreach ($process in @($Processes)) {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-PairScenario {
    param(
        [string] $Name,
        [int] $Iterations,
        [ValidateSet('None', 'Cpu', 'Process')]
        [string] $LoadMode = 'None',
        [int] $LoadCount = 0,
        [int] $GapMilliseconds = 0
    )

    Write-Host "Running $Name ($Iterations iterations)"
    $loadProcesses = @()
    if ($LoadMode -ne 'None') {
        $loadProcesses = @(Start-RunnerLoad -Mode $LoadMode -Count $LoadCount)
    }

    try {
        for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
            $before = Get-RunnerSnapshot
            $pairTimer = [System.Diagnostics.Stopwatch]::StartNew()
            $first = Invoke-PhpActivation -Phase 'skipif' -CallMethod $false
            if ($GapMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $GapMilliseconds
            }
            $second = Invoke-PhpActivation -Phase 'file' -CallMethod $true
            $pairTimer.Stop()
            $after = Get-RunnerSnapshot

            $results.Add([pscustomobject]@{
                ImageOS = $env:ImageOS
                ImageVersion = $env:ImageVersion
                Replica = $Replica
                Scenario = $Name
                Iteration = $iteration
                LoadMode = $LoadMode
                LoadCount = $LoadCount
                GapMilliseconds = $GapMilliseconds
                FirstSuccess = [bool]$first.success
                FirstCode = $first.code
                FirstHex = $first.hex
                FirstMessage = $first.message
                FirstCreateMilliseconds = $first.create_ms
                FirstProcessMilliseconds = $first.process_ms
                SecondSuccess = [bool]$second.success
                SecondCode = $second.code
                SecondHex = $second.hex
                SecondMessage = $second.message
                SecondCreateMilliseconds = $second.create_ms
                SecondProcessMilliseconds = $second.process_ms
                PairMilliseconds = $pairTimer.Elapsed.TotalMilliseconds
                CpuPercentBefore = $before.CpuPercent
                CpuPercentAfter = $after.CpuPercent
                AvailableMegabytesBefore = $before.AvailableMegabytes
                AvailableMegabytesAfter = $after.AvailableMegabytes
                ProcessCountBefore = $before.ProcessCount
                ProcessCountAfter = $after.ProcessCount
                ThreadCountAfter = $after.ThreadCount
                HandleCountAfter = $after.HandleCount
                IeProcessesAfter = $after.IeProcessCount
                IeLowUtilAfter = $after.IeLowUtilCount
            })
        }
    } finally {
        Stop-RunnerLoad -Processes $loadProcesses
        Start-Sleep -Seconds 2
    }
}

function Invoke-NativeScenario {
    param(
        [string] $Name,
        [string] $LoadMode,
        [int] $LoadCount
    )

    $nativeOutput = Join-Path $OutputDirectory "$Name-native.csv"
    $loadProcesses = @()
    if ($LoadMode -ne 'None') {
        $loadProcesses = @(Start-RunnerLoad -Mode $LoadMode -Count $LoadCount)
    }
    try {
        $windowsPowerShellX86 = "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
        & $windowsPowerShellX86 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $nativeScript `
            -Iterations 30 -Scenario $Name -OutputPath $nativeOutput
        $nativeExit = $LASTEXITCODE
        "Native scenario $Name exit code: $nativeExit" | Add-Content (Join-Path $OutputDirectory 'native-status.txt')
    } finally {
        Stop-RunnerLoad -Processes $loadProcesses
        Start-Sleep -Seconds 2
    }
}

# Record immutable runner and hardware information before adding load.
& {
    "TimestampUtc: $([DateTime]::UtcNow.ToString('o'))"
    "ImageOS: $env:ImageOS"
    "ImageVersion: $env:ImageVersion"
    "RunnerName: $env:RUNNER_NAME"
    "Replica: $Replica"
    "LogicalProcessors: $logicalProcessors"
    Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model, NumberOfProcessors, NumberOfLogicalProcessors, TotalPhysicalMemory, HypervisorPresent
    Get-CimInstance Win32_Processor | Format-List Name, Manufacturer, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, CurrentClockSpeed, L2CacheSize, L3CacheSize
    Get-CimInstance Win32_OperatingSystem | Format-List Caption, Version, BuildNumber, OSArchitecture, TotalVisibleMemorySize, FreePhysicalMemory, TotalVirtualMemorySize, FreeVirtualMemory
    Get-CimInstance Win32_PageFileUsage | Format-List Name, AllocatedBaseSize, CurrentUsage, PeakUsage
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Format-List ProductName, DisplayVersion, CurrentBuild, UBR, InstallationType
    & reg.exe query 'HKLM\SOFTWARE\Policies\Microsoft\Internet Explorer\Main' /v DisableInternetExplorerLaunchViaCOM 2>&1
    & reg.exe query 'HKCU\SOFTWARE\Policies\Microsoft\Internet Explorer\Main' /v DisableInternetExplorerLaunchViaCOM 2>&1
} 2>&1 | Out-File -LiteralPath (Join-Path $OutputDirectory 'runner-hardware.txt') -Encoding utf8
$global:LASTEXITCODE = 0

# Fixed-work CPU and process-launch measurements expose differences in runner capacity.
Add-Type -TypeDefinition @'
public static class FixedCpuBenchmark {
    public static ulong Run(long iterations) {
        ulong value = 1469598103934665603UL;
        for (long i = 0; i < iterations; i++) {
            value ^= (ulong)i;
            value *= 1099511628211UL;
            value ^= value >> 13;
        }
        return value;
    }
}
'@
[void][FixedCpuBenchmark]::Run(1000)
$cpuTimer = [Diagnostics.Stopwatch]::StartNew()
$cpuValue = [FixedCpuBenchmark]::Run(200000000)
$cpuTimer.Stop()
$launchTimer = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 100; $i++) {
    $process = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/d', '/c', 'exit', '0' -WindowStyle Hidden -PassThru -Wait
    $process.Dispose()
}
$launchTimer.Stop()
[pscustomobject]@{
    ImageOS = $env:ImageOS
    ImageVersion = $env:ImageVersion
    Replica = $Replica
    CpuBenchmarkMilliseconds = $cpuTimer.Elapsed.TotalMilliseconds
    CpuBenchmarkValue = $cpuValue
    ProcessLaunch100Milliseconds = $launchTimer.Elapsed.TotalMilliseconds
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'runner-benchmark.csv') -NoTypeInformation

Invoke-PairScenario -Name 'idle' -Iterations 40
foreach ($loadCount in @(1, 2, 3, 4, 6)) {
    Invoke-PairScenario -Name "cpu-$loadCount" -Iterations 25 -LoadMode Cpu -LoadCount $loadCount
}
Invoke-PairScenario -Name 'process-churn-6' -Iterations 25 -LoadMode Process -LoadCount 6

$saturationWorkers = [math]::Max(1, $logicalProcessors)
foreach ($gap in @(0, 25, 50, 100, 250, 500, 1000)) {
    Invoke-PairScenario -Name "saturated-gap-$gap" -Iterations 15 -LoadMode Cpu -LoadCount $saturationWorkers -GapMilliseconds $gap
}

Invoke-NativeScenario -Name 'native-idle' -LoadMode None -LoadCount 0
Invoke-NativeScenario -Name 'native-saturated' -LoadMode Cpu -LoadCount $saturationWorkers

$results | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'activation-results.csv') -NoTypeInformation
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'activation-results.json') -Encoding utf8
$results |
    Group-Object Scenario |
    ForEach-Object {
        $group = $_.Group
        [pscustomobject]@{
            Scenario = $_.Name
            Iterations = $group.Count
            FirstFailures = @($group | Where-Object { -not $_.FirstSuccess }).Count
            SecondFailures = @($group | Where-Object { -not $_.SecondSuccess }).Count
            AverageFirstCreateMilliseconds = [math]::Round(($group | Measure-Object FirstCreateMilliseconds -Average).Average, 2)
            AverageSecondCreateMilliseconds = [math]::Round(($group | Measure-Object SecondCreateMilliseconds -Average).Average, 2)
            PairsOverOneSecond = @($group | Where-Object PairMilliseconds -GT 1000).Count
            MinimumAvailableMegabytes = ($group | Measure-Object AvailableMegabytesAfter -Minimum).Minimum
        }
    } |
    Format-Table -AutoSize |
    Tee-Object -FilePath (Join-Path $OutputDirectory 'activation-summary.txt')

# Capture COM/DCOM and application events generated during the probe.
$startTime = [DateTime]::UtcNow.AddHours(-2)
Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $startTime } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'DistributedCOM|Service Control Manager' -or $_.Message -match 'Internet Explorer|iexplore|ielowutil|0002DF01' } |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
    Format-List |
    Out-File -LiteralPath (Join-Path $OutputDirectory 'system-com-events.txt') -Encoding utf8
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $startTime } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'Internet Explorer|iexplore|ielowutil|0002DF01' } |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
    Format-List |
    Out-File -LiteralPath (Join-Path $OutputDirectory 'application-com-events.txt') -Encoding utf8

$global:LASTEXITCODE = 0
