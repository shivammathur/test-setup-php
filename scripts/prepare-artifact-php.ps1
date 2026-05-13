param(
    [Parameter(Mandatory)] [string] $ArtifactDirectory,
    [Parameter(Mandatory)] [string] $PhpVersion,
    [Parameter(Mandatory)] [ValidateSet('x64', 'x86')] [string] $Arch,
    [Parameter(Mandatory)] [ValidateSet('nts', 'ts')] [string] $ThreadSafety,
    [Parameter(Mandatory)] [string] $Destination
)

$ErrorActionPreference = 'Stop'

$artifactDirectoryPath = Resolve-Path -Path $ArtifactDirectory
$zips = Get-ChildItem -Path $artifactDirectoryPath -Filter 'php-*.zip' -File -Recurse

if ($ThreadSafety -eq 'nts') {
    $candidates = $zips | Where-Object {
        $_.Name -match "^php-$([regex]::Escape($PhpVersion))\..+-nts-Win32-v[sc]\d+-$Arch\.zip$"
    }
} else {
    $candidates = $zips | Where-Object {
        $_.Name -match "^php-$([regex]::Escape($PhpVersion))\..+-Win32-v[sc]\d+-$Arch\.zip$" -and
        $_.Name -notmatch '-nts-'
    }
}

$zip = $candidates | Sort-Object Name | Select-Object -First 1
if ($null -eq $zip) {
    $available = ($zips | Select-Object -ExpandProperty Name | Sort-Object) -join "`n"
    throw "No PHP artifact zip found for PHP $PhpVersion $Arch $ThreadSafety. Available:`n$available"
}

if (Test-Path $Destination) {
    Remove-Item -Path $Destination -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

Write-Host "Expanding artifact $($zip.FullName)"
Expand-Archive -Path $zip.FullName -DestinationPath $Destination -Force

if (-not (Test-Path (Join-Path $Destination 'php.exe'))) {
    throw "php.exe was not found after extracting $($zip.Name)"
}

& (Join-Path $PSScriptRoot 'prepare-php-ini.ps1') -PhpDirectory $Destination

