param(
  [Parameter(Mandatory)] [string] $PhpRef,
  [Parameter(Mandatory)] [string] $Arch,
  [Parameter(Mandatory)] [string] $ThreadSafety,
  [Parameter(Mandatory)] [string] $BaselineRun,
  [Parameter(Mandatory)] [string] $Bzip2RsRun,
  [string] $Output = 'results/system.json'
)

$ErrorActionPreference = 'Stop'

$processor = Get-CimInstance Win32_Processor | Select-Object -First 1
$computer = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem

$info = [ordered]@{
  benchmark = [ordered]@{
    php_ref = $PhpRef
    arch = $Arch
    thread_safety = $ThreadSafety
    baseline_run = $BaselineRun
    bzip2_rs_run = $Bzip2RsRun
  }
  runner = [ordered]@{
    name = $env:RUNNER_NAME
    os = $env:RUNNER_OS
    arch = $env:RUNNER_ARCH
    environment = $env:RUNNER_ENVIRONMENT
    image_os = $env:ImageOS
    image_version = $env:ImageVersion
    github_run_id = $env:GITHUB_RUN_ID
    github_run_attempt = $env:GITHUB_RUN_ATTEMPT
    github_job = $env:GITHUB_JOB
  }
  machine = [ordered]@{
    name = $env:COMPUTERNAME
    manufacturer = $computer.Manufacturer
    model = $computer.Model
    system_type = $computer.SystemType
    hypervisor_present = $computer.HypervisorPresent
    total_physical_memory_gb = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
  }
  processor = [ordered]@{
    name = ($processor.Name -replace '\s+', ' ').Trim()
    manufacturer = $processor.Manufacturer
    description = $processor.Description
    architecture = $processor.Architecture
    address_width = $processor.AddressWidth
    cores = $processor.NumberOfCores
    logical_processors = $processor.NumberOfLogicalProcessors
    max_clock_speed_mhz = $processor.MaxClockSpeed
    l2_cache_kb = $processor.L2CacheSize
    l3_cache_kb = $processor.L3CacheSize
  }
  os = [ordered]@{
    caption = $os.Caption
    version = $os.Version
    build_number = $os.BuildNumber
    architecture = $os.OSArchitecture
  }
}

$outputPath = Join-Path (Get-Location) $Output
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null
$info | ConvertTo-Json -Depth 6 | Set-Content -Path $outputPath -Encoding utf8

Write-Host "Processor: $($info.processor.name)"
Write-Host "Cores/logical processors: $($info.processor.cores)/$($info.processor.logical_processors)"
Write-Host "Runner image: $($info.runner.image_os) $($info.runner.image_version)"
