param([string]$Source = './setup-php/src/scripts/extensions/add_extensions.ps1')
$ErrorActionPreference = 'Stop'
. $Source
$root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$php_dir = Join-Path $root 'php'
$ext_dir = Join-Path $php_dir 'ext'
New-Item $ext_dir -ItemType Directory -Force > $null
$installed = [pscustomobject]@{ VCVersion = 17; FullVersion = '8.5.12' }
$arch = 'x64'
$nightly_versions = '8.[6-9]'
$tick = 'PASS'
$cross = 'FAIL'
$script:checks = 0
function Get-PhpExtension { param($Path) return $script:existing }
function Get-PhpIniKey { param($Key, $Path) return $script:ini }
function Set-PhpIniKey { param($Key, $Value, $Path, [switch]$Delete) $script:ini = $Value }
function Set-ExtensionPrerequisites { param($extension) }
function Enable-Extension { param($extension) }
function Add-Log { param($mark, $subject, $message) if ($mark -eq 'FAIL') { throw $message } }
function Install-PhpExtension {
  param($Extension, $MinimumStability, $MaximumStability, $Path, $AdditionalFilesPath, $NoDependencies, $Version)
  $script:captured = @{} + $PSBoundParameters
  if ($script:existing -and $script:ini -ne 'Off') { throw 'Startup errors were not suppressed during replacement' }
  if ($script:installFails) { throw 'Simulated download failure' }
  Set-Content (Join-Path $ext_dir "php_$Extension.dll") 'new binary'
}
function Check-Case {
  param($label, $phpVersion, $parameters, $existing, $minimum, $maximum, $pin = '')
  Remove-Item (Join-Path $ext_dir '*') -Recurse -Force -ErrorAction SilentlyContinue
  $script:version = $phpVersion
  $script:existing = $existing
  $script:captured = $null
  $script:ini = 'On'
  $script:installFails = $false
  if ($existing -and $existing.State -ne 'Builtin') { Set-Content (Join-Path $ext_dir 'php_example.dll') 'old binary' }
  Add-Extension @parameters
  if ($null -eq $minimum) {
    if ($script:captured) { throw "$label unexpectedly reinstalled extension" }
  } else {
    if (!$script:captured) { throw "$label did not resolve the channel" }
    if ($script:captured.MinimumStability -ne $minimum -or $script:captured.MaximumStability -ne $maximum) { throw "$label selected wrong stability range" }
    if ($pin -ne '' -and $script:captured.Version -ne $pin) { throw "$label changed the explicit version pin" }
  }
  if ($script:ini -ne 'On') { throw "$label did not restore startup-error configuration" }
  $script:checks++
  Write-Output "PASS: $label"
}
try {
  $old = [pscustomobject]@{ Name = 'example'; Handle = 'example'; Version = '1.0.0'; State = 'Enabled' }
  $builtin = [pscustomobject]@{ Name = 'example'; Handle = 'example'; Version = '8.5.12'; State = 'Builtin' }
  foreach ($state in 'beta', 'alpha', 'devel', 'snapshot', 'stable') {
    Check-Case "$state fresh install" '8.5' @{ extension='example'; stability=$state } $null $state 'stable'
    Check-Case "$state upgrades an installed release" '8.5' @{ extension='example'; stability=$state } $old $state 'stable'
  }
  Check-Case 'Bare extension preserves installed version' '8.5' @{ extension='example' } $old $null $null
  Check-Case 'Builtin extension is preserved' '8.5' @{ extension='example'; stability='beta' } $builtin $null $null
  Check-Case 'Explicit stable remains strict on PHP 8.3' '8.3' @{ extension='example'; stability='stable' } $null 'stable' 'stable'
  Check-Case 'Bare extension preserves legacy DLL fallback' '8.3' @{ extension='example' } $null 'snapshot' 'stable'
  Check-Case 'Explicit beta pin retains exact state' '8.5' @{ extension='example'; stability='beta'; extension_version='1.2.3' } $old 'beta' 'beta' '1.2.3'
  Check-Case 'Explicit stable pin retains its version' '8.5' @{ extension='example'; stability='stable'; extension_version='1.2.3' } $old 'stable' 'stable' '1.2.3'
  Remove-Item (Join-Path $ext_dir '*') -Recurse -Force
  $script:existing = $old
  $script:version = '8.5'
  $script:ini = 'On'
  $script:installFails = $true
  Set-Content (Join-Path $ext_dir 'php_example.dll') 'old binary'
  $failed = $false
  try { Add-Extension example beta } catch { $failed = $true }
  if (!$failed -or (Get-Content (Join-Path $ext_dir 'php_example.dll') -Raw).Trim() -ne 'old binary' -or $script:ini -ne 'On') { throw 'Rollback failed' }
  $script:checks++
  Write-Output "PASS: $script:checks PowerShell checks, including rollback"
} finally {
  Remove-Item $root -Recurse -Force
}
