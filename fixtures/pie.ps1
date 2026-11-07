$ErrorActionPreference = 'Stop'
. "$env:GITHUB_WORKSPACE\setup-php\src\scripts\run.ps1"
Set-Location $env:GITHUB_WORKSPACE
New-Item artifacts -ItemType Directory -Force >$null
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Verify($extension, $expected) {
  php fixtures/pie-verify.php $extension $expected
  Assert ($LASTEXITCODE -eq 0) 'Extension verification failed'
}
try {
  if ($env:PIE_CHANNEL -eq 'nightly') { Add-Tool https://php.github.io/pie/pie-nightly.phar pie '-V' }
  if ($env:TARGET_PHP -ne '8.0') {
    node fixtures/pie-timing.cjs start binary
    Add-PieExtension fastjson 0.10.2 $false
    node fixtures/pie-timing.cjs end binary
    Copy-Item "$env:TEMP/pie-fastjson.log" artifacts/pie-binary.log
    Verify fastjson 0.10.2
    $pieFile = Join-Path $bin_dir 'pie'
    Move-Item $pieFile "$pieFile.saved"
    node fixtures/pie-timing.cjs start loaded
    Add-PieExtension fastjson 'iliaal/fastjson:0.10.2' $false
    node fixtures/pie-timing.cjs end loaded
    Assert (-not (Test-Path $pieFile)) 'Loaded extension caused a PIE download'
    Move-Item "$pieFile.saved" $pieFile
    $failed = $false
    try { Add-PieExtension fastjson 'iliaal/fastjson:99.99.99' $false } catch { $failed = $true }
    Assert $failed 'Wrong installed version incorrectly satisfied a pin'
    Verify fastjson 0.10.2
    Disable-PhpExtension -Extension fastjson -Path $php_dir
    node fixtures/pie-timing.cjs start reenable
    Add-PieExtension fastjson 'iliaal/fastjson:0.10.2' $false
    node fixtures/pie-timing.cjs end reenable
    Verify fastjson 0.10.2
  }
  node fixtures/pie-timing.cjs start source_blocked
  $failed = $false
  try { Add-PieExtension apcu 'apcu/apcu:5.1.28' $false } catch { $failed = $true }
  Assert $failed 'Source-only APCu release unexpectedly installed'
  node fixtures/pie-timing.cjs end source_blocked
  $log = Get-Content "$env:TEMP/pie-apcu.log" -Raw
  Assert ($log -match 'Could not find.*release asset|Failed to find|No.*download|Could not find a way to download') 'PIE failed for an unexpected reason'
  if ($env:TARGET_PHP -eq '8.0') {
    Assert ($log -match 'Target PHP installation:.*8.0\.') 'PIE did not target PHP 8.0'
    Assert (Test-Path "$bin_dir/pie-cli.exe") 'Standalone PIE missing'
  }
  Write-Host 'PIE Windows checks passed'
} finally {
  Get-ChildItem "$env:TEMP/pie-*.log" -ErrorAction SilentlyContinue | Copy-Item -Destination artifacts
}
