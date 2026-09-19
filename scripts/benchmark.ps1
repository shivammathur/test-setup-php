param([string]$Errors, [string]$Verbosity)
$ErrorActionPreference = 'Stop'
$env:SETUP_PHP_TRACE = '0'
. ./action/src/scripts/win32.ps1 '8.3' 'production'
PhpManager\Set-PhpIniKey -Key display_errors -Value On -Path "$php_dir/php.ini"
PhpManager\Set-PhpIniKey -Key display_startup_errors -Value $Errors -Path "$php_dir/php.ini"
New-Item evidence -ItemType Directory -Force | Out-Null

# Count direct calls made by Add-Extension; PhpManager's internal calls keep their module scope.
function Get-PhpIniKey {
  param([string]$Key, [string]$Path)
  $script:metrics.ini_reads++
  PhpManager\Get-PhpIniKey @PSBoundParameters
}
function Set-PhpIniKey {
  param([string]$Key, [string]$Value, [string]$Path, [switch]$Delete)
  $script:metrics.ini_writes++
  PhpManager\Set-PhpIniKey @PSBoundParameters
}
function Get-PhpExtension {
  param([string]$Path)
  if ($Path.EndsWith('.dll')) { $script:metrics.dll_inspections++ } else { $script:metrics.extension_scans++ }
  PhpManager\Get-PhpExtension @PSBoundParameters
}

$sources = @{
  original = './scripts/before-fixes.ps1'
  previous = './scripts/before-optimization.ps1'
  optimized = './action/src/scripts/extensions/add_extensions.ps1'
}
$orders = @(
  @('original', 'previous', 'optimized'),
  @('optimized', 'original', 'previous'),
  @('previous', 'optimized', 'original')
)
$results = @()

# Verify a fresh versioned install does not enter the recovery path.
PhpManager\Disable-PhpExtension -Extension redis -Path $php_dir
Remove-Item "$ext_dir/php_redis.dll", "$ext_dir/redis-6.1.0" -Force
. $sources.optimized
$script:metrics = [ordered]@{ini_reads=0; ini_writes=0; extension_scans=0; dll_inspections=0}
if ($Verbosity -eq 'vvv') { Set-PSDebug -Trace 2 }
try { Add-Extension redis stable 6.1.0 } finally { Set-PSDebug -Off }
if ($metrics.ini_reads -ne 0 -or $metrics.ini_writes -ne 0 -or $metrics.extension_scans -ne 1) { throw 'Fresh installs did extra INI work or extension scans' }
$metrics | ConvertTo-Json | Set-Content evidence/fresh-install-calls.json

for ($round = 0; $round -lt $orders.Count; $round++) {
  foreach ($variant in $orders[$round]) {
    . $sources[$variant]
    foreach ($case in @('common', 'cache-without-active', 'cache-with-active')) {
      if ($case -eq 'cache-without-active') { Remove-Item "$ext_dir/php_redis.dll" -Force }
      $script:metrics = [ordered]@{ini_reads=0; ini_writes=0; extension_scans=0; dll_inspections=0}
      $timer = [System.Diagnostics.Stopwatch]::new()
      if ($Verbosity -eq 'vvv') { Set-PSDebug -Trace 2 }
      try {
        $timer.Start()
        switch ($case) {
          common {
            Add-Extension openssl
            Add-Extension curl
            Add-Extension mbstring
          }
          cache-without-active { Add-Extension redis stable 6.1.0 }
          cache-with-active {
            Add-Extension redis stable 6.2.0
            Add-Extension redis stable 6.1.0
          }
        }
      } finally {
        $timer.Stop()
        Set-PSDebug -Off
      }
      $startup = PhpManager\Get-PhpIniKey -Key display_startup_errors -Path "$php_dir/php.ini"
      if ($startup -ne $Errors) { throw "INI setting changed for $variant / $case" }
      $runtime = php -d display_errors=0 -d display_startup_errors=0 -r 'echo json_encode(["redis"=>phpversion("redis"),"common"=>extension_loaded("openssl") && extension_loaded("curl") && extension_loaded("mbstring")]);' | ConvertFrom-Json
      if (-not $runtime.common -or ($case -ne 'common' -and $runtime.redis -ne '6.1.0')) { throw "Extensions failed to load for $variant / $case" }
      if ($variant -eq 'optimized') {
        if ($case -eq 'common' -and ($metrics.ini_reads -ne 0 -or $metrics.ini_writes -ne 0 -or $metrics.extension_scans -ne 3)) { throw 'Common installs did extra INI work or extension scans' }
        if ($Errors -eq 'Off' -and $metrics.ini_writes -ne 0) { throw 'Already-disabled startup errors caused INI writes' }
        if ($case -eq 'cache-without-active' -and ($metrics.extension_scans -ne 1 -or $metrics.dll_inspections -ne 0)) { throw 'Cache reuse without an active DLL did a preliminary scan' }
        if ($case -eq 'cache-with-active' -and ($metrics.extension_scans -ne 2 -or $metrics.dll_inspections -ne 2)) { throw 'Cache reuse did not use single-DLL inspection' }
      }
      $results += [ordered]@{
        round=$round; variant=$variant; case=$case; errors=$Errors; verbosity=$Verbosity
        milliseconds=$timer.Elapsed.TotalMilliseconds; calls=$metrics; startup=$startup; runtime=$runtime
      }
      $results | ConvertTo-Json -Depth 6 | Set-Content evidence/benchmark.json
    }
  }
}
$results | ConvertTo-Json -Depth 6
