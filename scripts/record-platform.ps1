$ErrorActionPreference='Stop'
New-Item reports -ItemType Directory -Force | Out-Null
$files=@(foreach ($directory in 'System32','SysWOW64') {
    foreach ($name in 'ntdll.dll','kernel32.dll','KernelBase.dll','ucrtbase.dll','vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll') {
        $file=Join-Path "$env:WINDIR/$directory" $name
        if (Test-Path $file) { @{path=$file;version=(Get-Item $file).VersionInfo.FileVersion;sha256=(Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()} }
    }
})
@{
    runnerImage=$env:ImageOS;runnerImageVersion=$env:ImageVersion
    os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
    cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)
    system=Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,NumberOfLogicalProcessors,TotalPhysicalMemory,HypervisorPresent
    scheduling=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' | Select-Object Win32PrioritySeparation
    files=$files
} | ConvertTo-Json -Depth 8 | Set-Content reports/platform.json
