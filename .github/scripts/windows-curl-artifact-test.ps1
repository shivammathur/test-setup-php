param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactsDirectory,
    [Parameter(Mandatory = $true)]
    [string]$ServerBaseUrl,
    [Parameter(Mandatory = $true)]
    [string]$ClientScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runtimeZips = Get-ChildItem -Path $ArtifactsDirectory -Recurse -File -Filter 'php-*.zip' |
    Where-Object {
        $_.Name -notmatch 'src|debug|devel|test|pdb'
    } |
    Sort-Object FullName

if ($runtimeZips.Count -eq 0) {
    throw "Could not find runtime PHP zip files under $ArtifactsDirectory"
}

Write-Host "Testing $($runtimeZips.Count) runtime artifact(s)"
$testedLabels = @()

foreach ($zip in $runtimeZips) {
    $label = [System.IO.Path]::GetFileNameWithoutExtension($zip.Name)
    $extractDir = Join-Path $env:RUNNER_TEMP ("extract-" + $label)
    $phpRoot = Join-Path $env:RUNNER_TEMP ("php-" + $label)

    if (Test-Path $extractDir) {
        Remove-Item -Path $extractDir -Recurse -Force
    }

    if (Test-Path $phpRoot) {
        Remove-Item -Path $phpRoot -Recurse -Force
    }

    New-Item -Path $extractDir -ItemType Directory -Force | Out-Null
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $extractDir -Force

    $phpExe = Get-ChildItem -Path $extractDir -Recurse -File -Filter 'php.exe' | Select-Object -First 1
    if ($null -eq $phpExe) {
        throw "Could not find php.exe after extracting $($zip.FullName)"
    }

    New-Item -Path $phpRoot -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $phpExe.Directory.FullName '*') -Destination $phpRoot -Recurse -Force

    $extensionDir = (Join-Path $phpRoot 'ext').Replace('\', '/')
    $iniPath = Join-Path $phpRoot 'curl-test.ini'
    @"
extension_dir="$extensionDir"
extension=php_curl.dll
date.timezone=UTC
display_errors=1
log_errors=0
"@ | Set-Content -Path $iniPath -Encoding Ascii

    $previousPath = $env:PATH
    $env:PATH = "$phpRoot;$extensionDir;$previousPath"

    try {
        $phpVersion = & (Join-Path $phpRoot 'php.exe') -n -d extension_dir="$extensionDir" -d extension=php_curl.dll -r "echo PHP_VERSION, ' ', PHP_ZTS ? 'TS' : 'NTS';"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to load php_curl.dll for $label"
        }

        Write-Host "Running curl encoding tests for $label ($phpVersion)"
        & (Join-Path $phpRoot 'php.exe') -c $iniPath $ClientScript $ServerBaseUrl $label
        if ($LASTEXITCODE -ne 0) {
            throw "Curl encoding validation failed for $label"
        }
    } finally {
        $env:PATH = $previousPath
    }

    $testedLabels += $label
}

Write-Host "Validated runtimes:"
$testedLabels | ForEach-Object { Write-Host "- $_" }
