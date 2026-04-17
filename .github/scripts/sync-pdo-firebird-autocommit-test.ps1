[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $TestsRoot,
    [string] $SourceUrl = 'https://raw.githubusercontent.com/shivammathur/php-src/fix-firebird-test/ext/pdo_firebird/tests/autocommit.phpt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $TestsRoot)) {
    throw "PDO Firebird tests root was not found at $TestsRoot"
}

$destinationPath = Join-Path $TestsRoot 'autocommit.phpt'
$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("autocommit-" + [System.Guid]::NewGuid().ToString('N') + '.phpt')

try {
    Invoke-WebRequest -Uri $SourceUrl -UseBasicParsing -OutFile $tempFile

    $downloadedFile = Get-Item -LiteralPath $tempFile -ErrorAction Stop
    if ($downloadedFile.Length -le 0) {
        throw "Downloaded autocommit.phpt from $SourceUrl was empty."
    }

    Move-Item -LiteralPath $tempFile -Destination $destinationPath -Force
    Write-Host "Replaced $destinationPath from $SourceUrl"
} finally {
    if (Test-Path $tempFile) {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}
