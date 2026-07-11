param(
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Continue'
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$output = Join-Path $OutputDirectory 'system-diagnostics.txt'

& {
    "Timestamp: $([DateTime]::UtcNow.ToString('o'))"
    "ImageOS: $env:ImageOS"
    "ImageVersion: $env:ImageVersion"
    "RunnerArchitecture: $env:RUNNER_ARCH"
    "PowerShell: $($PSVersionTable.PSVersion)"
    "Process64Bit: $([Environment]::Is64BitProcess)"
    "OS64Bit: $([Environment]::Is64BitOperatingSystem)"
    Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsName, OsVersion, OsBuildNumber

    '--- IE COM blocking policies ---'
    foreach ($scope in @('HKLM', 'HKCU')) {
        & reg.exe query "$scope\SOFTWARE\Policies\Microsoft\Internet Explorer\Main" /v DisableInternetExplorerLaunchViaCOM 2>&1
        & reg.exe query "$scope\SOFTWARE\Policies\Microsoft\Internet Explorer\Main" /v DisableInternetExplorerApp 2>&1
    }

    '--- COM registration by registry view ---'
    $clsid = '{0002DF01-0000-0000-C000-000000000046}'
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
        "Registry view: $view"
        $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::ClassesRoot, $view)
        foreach ($subPath in @(
            'InternetExplorer.Application\CLSID',
            "CLSID\$clsid",
            "CLSID\$clsid\LocalServer32",
            "CLSID\$clsid\ProgID"
        )) {
            $key = $root.OpenSubKey($subPath)
            if ($null -eq $key) {
                "$subPath = <missing>"
            } else {
                "$subPath = $($key.GetValue(''))"
                foreach ($name in $key.GetValueNames()) {
                    "  $name = $($key.GetValue($name))"
                }
                $key.Dispose()
            }
        }
        $root.Dispose()
    }

    '--- IE-related binaries ---'
    foreach ($path in @(
        "$env:ProgramFiles\Internet Explorer\iexplore.exe",
        "${env:ProgramFiles(x86)}\Internet Explorer\iexplore.exe",
        "$env:SystemRoot\System32\ieframe.dll",
        "$env:SystemRoot\SysWOW64\ieframe.dll"
    )) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path
            "$path | $($item.VersionInfo.FileVersion) | $($item.Length) bytes"
            Get-AuthenticodeSignature -LiteralPath $path | Select-Object Status, StatusMessage, SignerCertificate
        } else {
            "$path | <missing>"
        }
    }

    '--- Optional features ---'
    Get-WindowsOptionalFeature -Online |
        Where-Object FeatureName -Match 'Internet|Explorer|Browser' |
        Select-Object FeatureName, State

    '--- Relevant processes before tests ---'
    Get-Process -Name iexplore,msedge -ErrorAction SilentlyContinue |
        Select-Object Id, ProcessName, StartTime, Path
} 2>&1 | Tee-Object -FilePath $output

