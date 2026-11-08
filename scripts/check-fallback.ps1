$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module PhpManager -RequiredVersion 1.36.1
$root = Join-Path $env:RUNNER_TEMP r2-fallback
$diagnostics = Join-Path $env:GITHUB_WORKSPACE diagnostics
New-Item $root, $diagnostics -ItemType Directory -Force | Out-Null
Start-Transcript "$diagnostics/transcript.txt"
$tsSuffix = if ($env:PHP_TS -eq 'nts') { '-nts' } else { '' }
$branch = if ($env:PHP_VERSION -eq '8.6') { 'PHP-8.6' } else { 'master' }
$header = (Microsoft.PowerShell.Utility\Invoke-WebRequest "https://raw.githubusercontent.com/php/php-src/$branch/main/php_version.h").Content
if ($header -notmatch 'PHP_VERSION "([^"]+)"') { throw 'Could not resolve PHP version' }
$semver = $Matches[1]
$fixtures = @{}
foreach ($version in @("$env:PHP_VERSION.0-dev", $semver) | Select-Object -Unique) {
  $asset = "php-$version$tsSuffix-Win32-vs18-$env:PHP_ARCH.zip"
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    & gh release download "php$env:PHP_VERSION" --repo shivammathur/php-builder-windows --pattern $asset --dir $root --clobber
    if ($LASTEXITCODE -eq 0) { break }
  }
  if ($LASTEXITCODE -ne 0) { throw "Failed to obtain PHP archive fixture: $asset" }
  $fixtures[$asset] = Join-Path $root $asset
  Get-FileHash $fixtures[$asset] | Format-List
}
$hashes = Get-Content "$PSScriptRoot/extension-sha256.json" -Raw | ConvertFrom-Json -AsHashtable
$requestState = @{requests=[System.Collections.Generic.List[string]]::new(); failMirror=$false}
function Invoke-WebRequest {
  param([string]$Uri, [string]$OutFile, [int]$TimeoutSec)
  if ($Uri -like 'https://github.com/shivammathur/php-extensions-windows/*') {
    $requestState.requests.Add("github:$Uri")
    throw "Injected GitHub HTTP 504: $Uri"
  }
  if ($Uri -like 'https://artifacts.php-extensions-windows.setup-php.com/*') {
    $requestState.requests.Add("r2:$Uri")
    if ($requestState.failMirror) { throw 'Injected mirror outage' }
    Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec
    return
  }
  if ($Uri -like '*php-builder-windows*' -and $Uri -like '*.zip') {
    $fileName = $Uri.Split('/')[-1]
    if (-not $fixtures.ContainsKey($fileName)) { throw "Unexpected archive selection: $Uri" }
    Copy-Item $fixtures[$fileName] $OutFile -Force
    return
  }
  if ($Uri -like '*main/php_version.h') { return $header }
  if ($OutFile) { Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $Uri -OutFile $OutFile -TimeoutSec $TimeoutSec }
  else { Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $Uri -TimeoutSec $TimeoutSec }
}
$results = @()
foreach ($installer in 'Get-Php.ps1', 'Get-PhpNightly.ps1') {
  foreach ($outage in $false, $true) {
    $requestState.failMirror = $outage
    $requestState.requests.Clear()
    $dir = Join-Path $root "$installer-$outage"
    $installerError = $null
    try {
      & "$env:GITHUB_WORKSPACE/installers/$installer" -Version $env:PHP_VERSION -Architecture $env:PHP_ARCH -ThreadSafe ($env:PHP_TS -eq 'ts') -Path $dir
    } catch { $installerError = $_.Exception.Message }
    if (-not $outage -and $installerError) { throw $installerError }
    if ($outage -and $installerError -notlike '*Failed to download the assets*php-extensions-windows*') { throw "Unexpected outage outcome: $installerError" }
    $githubCount = @($requestState.requests | Where-Object { $_ -like 'github:*' }).Count
    $mirrorCount = @($requestState.requests | Where-Object { $_ -like 'r2:*' }).Count
    if ($githubCount -ne $(if ($outage) { 3 } else { 6 })) { throw "Unexpected primary attempts: $githubCount" }
    if ($mirrorCount -ne $(if ($outage) { 1 } else { 2 })) { throw "Unexpected mirror attempts: $mirrorCount" }
    $php = Get-Php -Path $dir
    if ($php.ExtensionsPath.TrimEnd('\') -ne "$dir\ext") { throw "Incorrect extension directory: $($php.ExtensionsPath)" }
    Enable-PhpExtension -Extension openssl,curl,mbstring -Path $dir
    $core = & "$dir/php.exe" -r 'echo json_encode(get_loaded_extensions()), PHP_EOL; exit(extension_loaded("openssl") && extension_loaded("curl") && extension_loaded("mbstring") ? 0 : 42);'
    if ($LASTEXITCODE -ne 0) { throw "Core extension loading failed: $core" }
    $extensions = @{}
    if (-not $outage) {
      foreach ($extension in 'xdebug', 'pcov') {
        $name = "php$env:PHP_VERSION`_$env:PHP_TS`_$env:PHP_ARCH`_$extension.dll"
        $hash = (Get-FileHash "$dir/ext/php_$extension.dll" -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $hashes[$name]) { throw "Mirror checksum mismatch for $name" }
        $option = if ($extension -eq 'xdebug') { 'zend_extension' } else { 'extension' }
        $output = & "$dir/php.exe" -d "$option=php_$extension.dll" -r "echo phpversion('$extension'), PHP_EOL; exit(extension_loaded('$extension') ? 0 : 43);" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to load $extension`: $output" }
        $extensions[$extension] = @{sha256=$hash; version="$output"}
      }
    }
    Copy-Item "$dir/php.ini" "$diagnostics/$installer-$outage.ini"
    $results += @{installer=$installer; mirrorUnavailable=$outage; php=$php.FullVersion; extensionsPath=$php.ExtensionsPath; githubAttempts=$githubCount; mirrorAttempts=$mirrorCount; installerError=$installerError; core="$core"; extensions=$extensions}
    $results | ConvertTo-Json -Depth 6 | Set-Content "$diagnostics/results.json"
  }
}
$results | ConvertTo-Json -Depth 6
Stop-Transcript
