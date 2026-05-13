param(
    [Parameter(Mandatory)] [string] $ManifestUrl,
    [Parameter(Mandatory)] [string] $PhpVersion,
    [Parameter(Mandatory)] [ValidateSet('x64', 'x86')] [string] $Arch,
    [Parameter(Mandatory)] [ValidateSet('nts', 'ts')] [string] $ThreadSafety,
    [Parameter(Mandatory)] [string] $Destination
)

$ErrorActionPreference = 'Stop'

$manifest = Invoke-RestMethod -Uri $ManifestUrl
$line = $manifest.$PhpVersion
if ($null -eq $line) {
    throw "PHP $PhpVersion was not found in $ManifestUrl"
}

$entryName = $line.PSObject.Properties.Name |
    Where-Object { $_ -match "^$ThreadSafety-v[sc]\d+-$Arch$" } |
    Sort-Object |
    Select-Object -First 1

if (-not $entryName) {
    $available = ($line.PSObject.Properties.Name | Sort-Object) -join ', '
    throw "No Windows release entry found for PHP $PhpVersion $Arch $ThreadSafety. Available: $available"
}

$zipPath = $line.$entryName.zip.path
if (-not $zipPath) {
    throw "Release manifest entry $entryName for PHP $PhpVersion does not contain a zip path"
}

$downloadUrl = "https://downloads.php.net/~windows/releases/$zipPath"
$zipFile = Join-Path $env:RUNNER_TEMP $zipPath

Write-Host "Downloading latest PHP $PhpVersion release $entryName from $downloadUrl"
Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile

if (Test-Path $Destination) {
    Remove-Item -Path $Destination -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

Expand-Archive -Path $zipFile -DestinationPath $Destination -Force

if (-not (Test-Path (Join-Path $Destination 'php.exe'))) {
    throw "php.exe was not found after extracting $zipPath"
}

& (Join-Path $PSScriptRoot 'prepare-php-ini.ps1') -PhpDirectory $Destination

