$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PWD/setup-php/src/scripts/extensions/add_extensions.ps1"
$src = "$PWD/setup-php/src"
$php_dir = Split-Path (Get-Command php).Source
$ext_dir = php -r 'echo ini_get("extension_dir");'
if (![IO.Path]::IsPathRooted($ext_dir)) { $ext_dir = Join-Path $php_dir $ext_dir }
$installed = Get-Php -Path $php_dir
$version = $env:EXPECTED_PHP
$arch = $installed.Architecture
$nightly_versions = '8.[6-9]'
$tick = 'PASS'
$cross = 'FAIL'
$script:metadataCalls = 0
$script:archiveCalls = 0
$script:xdebugCalls = 0
$script:installerCalls = 0
$script:originalVersions = (Get-Command Get-PeclPackageVersion).ScriptBlock
function Get-PeclPackageVersion {
  param($Handle, $MinimumStability, $MaximumStability)
  $script:metadataCalls++
  & $script:originalVersions @PSBoundParameters
}
& (Get-Module PhpManager) {
  $script:reuseXdebugCalls = 0
  $script:reuseOriginalXdebug = (Get-Command Get-XdebugExtension).ScriptBlock
  function script:Get-XdebugExtension {
    param($PhpVersion, $Version, $MinimumStability, $MaximumStability)
    $script:reuseXdebugCalls++
    & $script:reuseOriginalXdebug @PSBoundParameters
  }
}
function Get-PeclArchiveUrl {
  $script:archiveCalls++
  throw 'An already-current installed DLL must not need archive discovery'
}
function Install-PhpExtension {
  $script:installerCalls++
  throw 'An already-current installed DLL must not be reinstalled'
}
function Set-PhpIniKey { throw 'Reuse must not rewrite startup-error configuration' }
function Add-Log {
  param($mark, $subject, $message)
  if ($mark -eq $cross) { throw "$subject $message : $($Error[0])" }
  Write-Output "$mark $subject $message"
}
$dll = Join-Path $ext_dir "php_$($env:EXTENSION).dll"
$beforeHash = (Get-FileHash $dll -Algorithm SHA256).Hash
$beforeTime = (Get-Item $dll).LastWriteTimeUtc
$watch = [Diagnostics.Stopwatch]::StartNew()
Add-Extension $env:EXTENSION $env:EXPECTED_STATE
$watch.Stop()
$script:xdebugCalls = & (Get-Module PhpManager) { $script:reuseXdebugCalls }
if ($beforeHash -ne (Get-FileHash $dll -Algorithm SHA256).Hash -or $beforeTime -ne (Get-Item $dll).LastWriteTimeUtc) { throw 'The installed DLL changed during reuse' }
if ($script:installerCalls -ne 0 -or $script:archiveCalls -ne 0) { throw 'Unexpected install work during reuse' }
if ($env:EXTENSION -eq 'xdebug') {
  if ($script:xdebugCalls -ne 1 -or $script:metadataCalls -gt 1) { throw 'Unexpected Xdebug lookup count' }
} elseif ($script:metadataCalls -ne 1) { throw 'Expected exactly one release-metadata lookup' }
$actual = php -r 'echo phpversion(getenv("EXTENSION"));'
if ($actual -ne $env:EXPECTED_VERSION) { throw "Version changed during reuse: $actual" }
[pscustomobject]@{
  extension = $env:EXTENSION
  state = $env:EXPECTED_STATE
  version = $actual
  metadataLookups = $script:metadataCalls
  xdebugLookups = $script:xdebugCalls
  archiveLookups = $script:archiveCalls
  installerCalls = $script:installerCalls
  dllUnchanged = $true
  milliseconds = $watch.Elapsed.TotalMilliseconds
} | ConvertTo-Json | Tee-Object evidence/reuse.json
