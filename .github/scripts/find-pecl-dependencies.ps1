[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Package,

    [Parameter(Mandatory = $true)]
    [string] $BuilderManifest,

    [Parameter(Mandatory = $false)]
    [string] $PhpVersion = '8.4',

    [Parameter(Mandatory = $false)]
    [ValidateSet('x86', 'x64')]
    [string] $Arch = 'x64',

    [Parameter(Mandatory = $false)]
    [string] $OutputPath = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module $BuilderManifest -Force

$builderRoot = Split-Path -Parent $BuilderManifest
$vsConfigPath = Join-Path $builderRoot 'config/vs.json'
$vsConfig = Get-Content -Path $vsConfigPath -Raw | ConvertFrom-Json
$majorMinor = if ($PhpVersion -eq 'master') { 'master' } else { $PhpVersion.Substring(0, 3) }
$vsVersion = $vsConfig.php.$majorMinor
if ([string]::IsNullOrWhiteSpace($vsVersion)) {
    throw "PHP version $PhpVersion is not supported by the builder."
}

function Get-ExtensionNameForPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageName
    )

    switch ($PackageName) {
        'oci8' { return 'oci8_19' }
        'pecl_http' { return 'http' }
        default { return $PackageName }
    }
}

function Get-PackageNameForExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExtensionName
    )

    if ($ExtensionName.Contains('oci8')) {
        return 'oci8'
    }
    if ($ExtensionName.Contains('ddtrace')) {
        return 'datadog_trace'
    }
    if ($ExtensionName -eq 'http') {
        return 'pecl_http'
    }
    return $ExtensionName
}

function Get-ComposerRequireLibraries {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageName,
        [Parameter(Mandatory = $true)]
        [string] $ExtensionName,
        [Parameter(Mandatory = $false)]
        [string] $ComposerPath
    )

    $packageName = Get-PackageNameForExtension -ExtensionName $ExtensionName
    $candidatePaths = @()
    if (-not [string]::IsNullOrWhiteSpace($ComposerPath)) {
        $candidatePaths += $ComposerPath
    }
    $candidatePaths += @(
        (Join-Path $builderRoot "config/stubs/$ExtensionName.composer.json"),
        (Join-Path $builderRoot "config/stubs/$packageName.composer.json"),
        (Join-Path $builderRoot "config/stubs/$PackageName.composer.json")
    )

    foreach ($candidatePath in $candidatePaths | Select-Object -Unique) {
        if (-not (Test-Path $candidatePath)) {
            continue
        }

        try {
            $composerJson = Get-Content $candidatePath -Raw | ConvertFrom-Json
            $libraries = @()
            if ($null -ne $composerJson.require) {
                $composerJson.require | ForEach-Object {
                    $_.PSObject.Properties | ForEach-Object {
                        if ($_.Name -notmatch '^ext-' -and $_.Name -ne 'php') {
                            $libraries += $_.Name
                        }
                    }
                }
            }
            return @($libraries | Select-Object -Unique)
        } catch {
            continue
        }
    }

    return @()
}

function Merge-Libraries {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]] $DetectedLibraries = @(),
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]] $ComposerLibraries = @()
    )

    $merged = @($DetectedLibraries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($library in $ComposerLibraries) {
        $libraryName = $library
        if ($library -match '^(.+?)-\d') {
            $libraryName = $Matches[1]
        }
        if (-not (($merged -join ' ') -like "*$libraryName*")) {
            $merged += $library
        }
    }

    return @($merged | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Sort-Object)
}

function New-Result {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Status,
        [Parameter(Mandatory = $true)]
        [string] $ExtensionName,
        [Parameter(Mandatory = $false)]
        [string[]] $Libraries = @(),
        [Parameter(Mandatory = $false)]
        [string] $Note = ''
    )

    return [PSCustomObject]@{
        package = $Package
        extension = $ExtensionName
        php_version = $PhpVersion
        arch = $Arch
        vs_version = $vsVersion
        status = $Status
        libraries = @($Libraries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        note = $Note
    }
}

$extension = Get-ExtensionNameForPackage -PackageName $Package
$result = $null
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pecl-$Package-" + [System.Guid]::NewGuid().ToString())
New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null

try {
    $archivePath = Join-Path $tempRoot "$Package.tgz"
    $downloaded = $false
    foreach ($candidate in @($Package, $Package.ToUpper()) | Select-Object -Unique) {
        try {
            Invoke-WebRequest -Uri "https://pecl.php.net/get/$candidate" -OutFile $archivePath
            $downloaded = $true
            break
        } catch {
        }
    }

    if (-not $downloaded) {
        $result = New-Result -Status 'fetch-failed' -ExtensionName $extension
    } else {
        $sourceDirectory = Join-Path $tempRoot 'src'
        New-Item -Path $sourceDirectory -ItemType Directory -Force | Out-Null
        & tar -xzf $archivePath -C $sourceDirectory

        $configPath = Get-RecursiveFilePath -Directory $sourceDirectory -FileName 'config.w32'
        $composerPath = Get-RecursiveFilePath -Directory $sourceDirectory -FileName 'composer.json'
        $composerLibraries = @(Get-ComposerRequireLibraries -PackageName $Package -ExtensionName $extension -ComposerPath $composerPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        if ($null -eq $configPath) {
            $result = New-Result -Status 'no-config.w32' -ExtensionName $extension
        } else {
            try {
                $configContent = [string](Get-Content -Path $configPath -Raw)
                $detectedLibraries = @(Get-LibrariesFromConfig -PhpVersion $PhpVersion -Extension $extension -VsVersion $vsVersion -Arch $Arch -ConfigW32Content $configContent |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $libraries = Merge-Libraries -DetectedLibraries $detectedLibraries -ComposerLibraries $composerLibraries
                $result = New-Result -Status 'ok' -ExtensionName $extension -Libraries $libraries
            } catch {
                $result = New-Result -Status 'detect-failed' -ExtensionName $extension -Note $_.Exception.Message
            }
        }
    }
} finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$json = $result | ConvertTo-Json -Depth 6
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path $OutputPath -Value $json -Encoding utf8
} else {
    $json
}
