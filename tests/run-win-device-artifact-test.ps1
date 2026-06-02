[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $Php,

  [Parameter(Mandatory = $true)]
  [string] $ExpectedZts,

  [string] $Label = 'php'
)

$ErrorActionPreference = 'Stop'

if (Test-Path $Php) {
  $php = (Resolve-Path $Php).Path
} else {
  $php = (Get-Command $Php).Source
}

$phpRoot = Split-Path $php -Parent
$env:PATH = "$phpRoot;$env:PATH"

Write-Host "label: $Label"
Write-Host "php.exe: $php"
Write-Host "php root: $phpRoot"

$script = Join-Path $PSScriptRoot 'win-device-paths.php'
& $php -n $script $ExpectedZts
if ($LASTEXITCODE -ne 0) {
  throw "Reserved device path test failed for $Label with exit code $LASTEXITCODE"
}
