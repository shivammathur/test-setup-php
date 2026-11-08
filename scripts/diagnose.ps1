$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'
$diagnostics = Join-Path $env:GITHUB_WORKSPACE diagnostics
New-Item $diagnostics -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$diagnostics/transcript.txt"
Write-Host "PHP=$env:PHP_VERSION PHPTS=$env:PHPTS Setup=$env:SETUP_OUTCOME"
$PSVersionTable | Format-List
Get-Module -ListAvailable PhpManager | Select-Object Name, Version, Path | Format-List
Import-Module PhpManager -Force
$module = Get-Module PhpManager
Copy-Item "$($module.ModuleBase)/private/Get-PhpExtensionDetail.ps1" "$diagnostics/" -ErrorAction Continue
Copy-Item "$($module.ModuleBase)/public/Enable-PhpExtension.ps1" "$diagnostics/" -ErrorAction Continue
$dumpbin = Get-ChildItem 'C:/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC/*/bin/Hostx64/x64/dumpbin.exe' | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
function Inspect-Php([string]$Directory, [string]$Label) {
  Write-Host "===== $Label $Directory ====="
  $out = Join-Path $diagnostics $Label
  New-Item $out -ItemType Directory -Force | Out-Null
  Get-ChildItem $Directory -Recurse -File | Select-Object FullName, Length | ConvertTo-Json -Depth 4 | Set-Content "$out/files.json"
  Get-ChildItem "$Directory/*.dll", "$Directory/ext/php_openssl.dll", "$Directory/ext/php_curl.dll", "$Directory/ext/php_mbstring.dll" | Get-FileHash | Format-Table -AutoSize | Out-String -Width 300 | Tee-Object "$out/hashes.txt"
  if (Test-Path "$Directory/COMMIT") { Get-Content "$Directory/COMMIT" }
  if (Test-Path "$Directory/php.ini") { Copy-Item "$Directory/php.ini" "$out/php.ini" }
  & "$Directory/php.exe" -n -v 2>&1 | Tee-Object "$out/version.txt"
  & "$Directory/php.exe" --ini 2>&1 | Tee-Object "$out/ini-path.txt"
  & "$Directory/php.exe" -n -i 2>&1 | Set-Content "$out/php-info.txt"
  try { Get-Php -Path $Directory | Format-List * | Out-String -Width 300 | Tee-Object "$out/phpmanager-php.txt" } catch { $_ | Format-List * -Force }
  try { Get-PhpExtension -Path $Directory | Format-Table -AutoSize | Out-String -Width 300 | Tee-Object "$out/phpmanager-extensions.txt" } catch { $_ | Format-List * -Force }
  foreach ($name in 'openssl', 'curl', 'mbstring', 'gd') {
    Write-Host "Direct extension load: $name"
    & "$Directory/php.exe" -n -d "extension_dir=$Directory/ext" -d "extension=$name" -r "echo json_encode(get_loaded_extensions()), PHP_EOL; exit(extension_loaded('$name') ? 0 : 42);" 2>&1 | Tee-Object "$out/load-$name.txt"
    Write-Host "Direct extension exit: $LASTEXITCODE"
    if (Test-Path "$Directory/ext/php_$name.dll") {
      try { Get-PhpExtension -Path "$Directory/ext/php_$name.dll" | Format-List * | Out-String | Tee-Object "$out/phpmanager-$name.txt" } catch { $_ | Format-List * -Force }
      if ($dumpbin) { & $dumpbin /dependents "$Directory/ext/php_$name.dll" | Tee-Object "$out/dependencies-$name.txt" }
    }
  }
  if ($dumpbin) {
    Get-ChildItem "$Directory/php*.dll", "$Directory/libssl*.dll", "$Directory/libcrypto*.dll", "$Directory/libcurl*.dll" | ForEach-Object {
      & $dumpbin /dependents $_.FullName | Set-Content "$out/dependencies-$($_.Name).txt"
    }
  }
}
Inspect-Php 'C:/tools/php' installed
try {
  $suffix = if ($env:PHPTS -eq 'ts') { '' } else { '-nts' }
  $asset = "php-$env:PHP_VERSION.0-dev$suffix-Win32-vs18-x64.zip"
  $url = "https://github.com/shivammathur/php-builder-windows/releases/download/php$env:PHP_VERSION/$asset"
  Write-Host "Pristine asset: $url"
  $zip = Join-Path $env:RUNNER_TEMP $asset
  Invoke-WebRequest $url -OutFile $zip -ErrorAction Stop
  Get-FileHash $zip | Format-List
  $pristine = Join-Path $env:RUNNER_TEMP pristine
  Expand-Archive $zip $pristine -Force -ErrorAction Stop
  Copy-Item "$pristine/php.ini-production" "$pristine/php.ini"
  Add-Content "$pristine/php.ini" "extension_dir=$pristine/ext"
  Inspect-Php $pristine pristine
} catch { $_ | Format-List * -Force }
Stop-Transcript
exit 0
