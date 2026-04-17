[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $PackageName,
    [Parameter(Mandatory = $true)]
    [string] $InstallRoot,
    [string] $DownloadBaseUrl = 'https://downloads.php.net/~windows/releases'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packageUrl = "$DownloadBaseUrl/$PackageName"
$downloadDirectory = Join-Path $env:RUNNER_TEMP 'manual-php-release'
$archivePath = Join-Path $downloadDirectory $PackageName

if (Test-Path $downloadDirectory) {
    Remove-Item -Path $downloadDirectory -Recurse -Force
}

if (Test-Path $InstallRoot) {
    Remove-Item -Path $InstallRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

Write-Host "Downloading released PHP from $packageUrl"
Invoke-WebRequest -Uri $packageUrl -UseBasicParsing -OutFile $archivePath

try {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $InstallRoot -Force
} catch {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $InstallRoot)
}

$phpExe = Join-Path $InstallRoot 'php.exe'
if (-not (Test-Path $phpExe)) {
    throw "php.exe was not found after extracting $PackageName to $InstallRoot"
}

if ($env:GITHUB_PATH) {
    Add-Content -Path $env:GITHUB_PATH -Value $InstallRoot
}

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "php-root=$InstallRoot"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "php-exe=$phpExe"
}

& $phpExe -n -v | Select-Object -First 1 | Out-Host
