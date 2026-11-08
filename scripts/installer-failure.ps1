$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module PhpManager -RequiredVersion 1.36.1
$root = Join-Path $env:RUNNER_TEMP interrupted-installer
$diagnostics = Join-Path $env:GITHUB_WORKSPACE diagnostics
New-Item $root, $diagnostics -ItemType Directory -Force | Out-Null
Start-Transcript "$diagnostics/transcript.txt"
$installer = Join-Path $root Get-PhpNightly.ps1
function Download-Fixture([string]$Tag, [string]$Asset) {
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & gh release download $Tag --repo shivammathur/php-builder-windows --pattern $Asset --dir $root --clobber
    if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $root $Asset))) { return }
    Start-Sleep -Seconds 2
  }
  throw "Could not download fixture $Tag/$Asset"
}
Download-Fixture php8.7 Get-PhpNightly.ps1
$fixture = Join-Path $root nightly.zip
$asset = "php-$env:PHP_VERSION.0-dev-nts-Win32-vs18-x64.zip"
Download-Fixture "php$env:PHP_VERSION" $asset
Move-Item (Join-Path $root $asset) $fixture -Force
Get-FileHash $installer, $fixture | Format-List
$original = Get-Content $installer -Raw
$optionalLine = '"xdebug", "pcov" | ForEach-Object'
$optionalIndex = $original.IndexOf($optionalLine)
$configIndex = $original.IndexOf('$ini_content = @(')
if ($optionalIndex -lt 0 -or $configIndex -le $optionalIndex) { throw 'Installer layout changed' }
# A test-only variant configures PHP before any optional download can throw.
$reordered = $original.Substring(0, $optionalIndex) + $original.Substring($configIndex).TrimEnd() + [Environment]::NewLine + $original.Substring($optionalIndex, $configIndex - $optionalIndex)
Set-Content "$root/reordered.ps1" $reordered
Copy-Item $installer, "$root/reordered.ps1" $diagnostics
function Invoke-WebRequest {
  param([string]$Uri, [string]$OutFile, [int]$TimeoutSec)
  if ($Uri -like '*php-extensions-windows*') { throw "Injected HTTP 504 for $Uri" }
  if ($Uri -like '*php-builder-windows*' -and $Uri -like '*.zip') {
    Copy-Item $fixture $OutFile -Force
    return
  }
  throw "Unexpected network request: $Uri"
}
$results = @()
foreach ($variant in 'original', 'reordered') {
  $dir = Join-Path $root $variant
  $script = if ($variant -eq 'original') { $installer } else { "$root/reordered.ps1" }
  $installerError = $null
  try { & $script -Architecture x64 -ThreadSafe $false -Path $dir -Version $env:PHP_VERSION } catch { $installerError = $_.Exception.Message }
  if ($installerError -notlike '*php-extensions-windows*') { throw "Did not reach injected failure: $installerError" }
  Write-Host "VARIANT=$variant INSTALLER_ERROR=$installerError"
  $php = Get-Php -Path $dir
  $php | Format-List *
  $enableError = $null
  try { Enable-PhpExtension -Extension openssl,curl,mbstring -Path $dir } catch { $enableError = $_.Exception.Message }
  Write-Host "ENABLE_ERROR=$enableError"
  $output = & "$dir/php.exe" -r 'echo json_encode(get_loaded_extensions()), PHP_EOL; exit(extension_loaded("openssl") && extension_loaded("curl") && extension_loaded("mbstring") ? 0 : 42);'
  $exitCode = $LASTEXITCODE
  Write-Host "LOADED=$output EXIT=$exitCode"
  Copy-Item "$dir/php.ini" "$diagnostics/$variant-php.ini"
  $results += [pscustomobject]@{variant=$variant; version=$php.FullVersion; extensionsPath=$php.ExtensionsPath; installerError=$installerError; enableError=$enableError; loaded=$output; exitCode=$exitCode}
}
$results | ConvertTo-Json -Depth 5 | Tee-Object "$diagnostics/results.json"
if ($results[0].enableError -notlike '*Unable to find a locally available extension*') { throw 'Original failure was not reproduced' }
if ($results[0].exitCode -ne 42) { throw 'Original unexpectedly loaded the extensions' }
if ($results[1].enableError -or $results[1].exitCode -ne 0) { throw 'Configuration-first variant failed' }
Stop-Transcript
exit 0
