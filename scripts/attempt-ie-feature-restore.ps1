param(
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Continue'
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$log = Join-Path $OutputDirectory 'ie-feature-restore.txt'
$featureName = 'Internet-Explorer-Optional-amd64'
$capabilityName = 'Browser.InternetExplorer~~~~0.0.11.0'

function Write-Section {
    param([string] $Title)
    "`n===== $Title =====" | Tee-Object -FilePath $log -Append
}

function Write-NativeExit {
    param([string] $Command)
    "$Command exit code: $LASTEXITCODE" | Tee-Object -FilePath $log -Append
    $global:LASTEXITCODE = 0
}

& {
    "TimestampUtc: $([DateTime]::UtcNow.ToString('o'))"
    "ImageOS: $env:ImageOS"
    "ImageVersion: $env:ImageVersion"
    Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsName, OsVersion, OsBuildNumber
} 2>&1 | Tee-Object -FilePath $log

Write-Section 'Server feature inventory before attempt'
Get-WindowsFeature 2>&1 |
    Where-Object { $_.Name -match 'Internet|Explorer|Browser' -or $_.DisplayName -match 'Internet Explorer' } |
    Format-Table -AutoSize |
    Tee-Object -FilePath $log -Append

Write-Section 'DISM optional feature lookup before attempt'
& dism.exe /Online /English /Get-FeatureInfo "/FeatureName:$featureName" 2>&1 |
    Tee-Object -FilePath $log -Append
Write-NativeExit -Command 'DISM Get-FeatureInfo'

Write-Section 'PowerShell optional feature inventory before attempt'
Get-WindowsOptionalFeature -Online 2>&1 |
    Where-Object { $_.FeatureName -match 'Internet|Explorer|Browser' } |
    Format-Table -AutoSize |
    Tee-Object -FilePath $log -Append

Write-Section 'Capability inventory before attempt'
Get-WindowsCapability -Online 2>&1 |
    Where-Object { $_.Name -match 'InternetExplorer|Browser' } |
    Format-Table -AutoSize |
    Tee-Object -FilePath $log -Append

Write-Section 'DISM capability lookup before attempt'
& dism.exe /Online /English /Get-CapabilityInfo "/CapabilityName:$capabilityName" 2>&1 |
    Tee-Object -FilePath $log -Append
Write-NativeExit -Command 'DISM Get-CapabilityInfo'

Write-Section 'Component-store package inventory'
Get-WindowsPackage -Online 2>&1 |
    Where-Object { $_.PackageName -match 'InternetExplorer|Internet-Explorer|Browser' } |
    Format-Table PackageName, PackageState, ReleaseType -AutoSize |
    Tee-Object -FilePath $log -Append

$packageFiles = @(
    Get-ChildItem "$env:SystemRoot\servicing\Packages" -Filter '*InternetExplorer*' -ErrorAction SilentlyContinue
    Get-ChildItem "$env:SystemRoot\servicing\Packages" -Filter '*Internet-Explorer*' -ErrorAction SilentlyContinue
)
"Matching servicing package files: $($packageFiles.Count)" | Tee-Object -FilePath $log -Append
$packageFiles | Select-Object Name, Length | Format-Table -AutoSize | Tee-Object -FilePath $log -Append

$winsxsDirectories = @(Get-ChildItem "$env:SystemRoot\WinSxS" -Directory -Filter '*internetexplorer*' -ErrorAction SilentlyContinue)
"Matching WinSxS directories: $($winsxsDirectories.Count)" | Tee-Object -FilePath $log -Append
$winsxsDirectories | Select-Object -First 100 -ExpandProperty Name | Tee-Object -FilePath $log -Append

Write-Section 'Attempt ServerManager feature installation'
try {
    $serverResult = Install-WindowsFeature -Name $featureName -IncludeAllSubFeature -ErrorAction Stop
    $serverResult | Format-List * | Tee-Object -FilePath $log -Append
} catch {
    "Install-WindowsFeature failed: $($_.Exception.GetType().FullName): $($_.Exception.Message)" |
        Tee-Object -FilePath $log -Append
}

Write-Section 'Attempt DISM optional feature installation'
& dism.exe /Online /English /Enable-Feature "/FeatureName:$featureName" /All /NoRestart 2>&1 |
    Tee-Object -FilePath $log -Append
$featureInstallExit = $LASTEXITCODE
Write-NativeExit -Command 'DISM Enable-Feature'

Write-Section 'Attempt Feature-on-Demand capability installation'
& dism.exe /Online /English /Add-Capability "/CapabilityName:$capabilityName" /NoRestart 2>&1 |
    Tee-Object -FilePath $log -Append
$capabilityInstallExit = $LASTEXITCODE
Write-NativeExit -Command 'DISM Add-Capability'

Write-Section 'Inventory after attempts'
& dism.exe /Online /English /Get-FeatureInfo "/FeatureName:$featureName" 2>&1 |
    Tee-Object -FilePath $log -Append
Write-NativeExit -Command 'DISM Get-FeatureInfo after'
& dism.exe /Online /English /Get-CapabilityInfo "/CapabilityName:$capabilityName" 2>&1 |
    Tee-Object -FilePath $log -Append
Write-NativeExit -Command 'DISM Get-CapabilityInfo after'

Write-Section '32-bit IE COM activation after attempts'
$x86PowerShell = "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
$activationCommand = @'
$ErrorActionPreference = 'Stop'
$rows = @()
for ($i = 1; $i -le 20; $i++) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $ie = $null
    try {
        $ie = New-Object -ComObject InternetExplorer.Application
        $ie.Quit()
        $rows += "PASS iteration=$i elapsed_ms=$($timer.ElapsedMilliseconds)"
    } catch {
        $hr = $_.Exception.HResult
        $unsigned = [uint32](([int64]$hr) -band 0xffffffffL)
        $rows += ('FAIL iteration={0} hresult=0x{1:X8} elapsed_ms={2} message={3}' -f $i, $unsigned, $timer.ElapsedMilliseconds, $_.Exception.Message)
    } finally {
        if ($null -ne $ie) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ie) }
    }
}
$rows
'@
& $x86PowerShell -NoLogo -NoProfile -NonInteractive -Command $activationCommand 2>&1 |
    Tee-Object -FilePath $log -Append

Write-Section 'Relevant DISM log lines'
Get-Content "$env:SystemRoot\Logs\DISM\dism.log" -Tail 2000 -ErrorAction SilentlyContinue |
    Select-String -Pattern 'Internet-Explorer|InternetExplorer|Browser.InternetExplorer|0x800f' |
    ForEach-Object Line |
    Tee-Object -FilePath (Join-Path $OutputDirectory 'dism-ie-lines.txt')

[pscustomobject]@{
    ImageOS = $env:ImageOS
    ImageVersion = $env:ImageVersion
    FeatureName = $featureName
    FeatureInstallExitCode = $featureInstallExit
    CapabilityName = $capabilityName
    CapabilityInstallExitCode = $capabilityInstallExit
    ServicingPackageFileCount = $packageFiles.Count
    WinSxSDirectoryCount = $winsxsDirectories.Count
    RestartSupportedByHostedRunner = $false
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'restore-result.json') -Encoding utf8

$global:LASTEXITCODE = 0

