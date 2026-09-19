param([string]$Phase, [string]$ExpectedVersion, [string]$ExpectedStartup = '')
$ErrorActionPreference='Stop'
$root=Split-Path (Get-Command php).Source
$ext=Join-Path $root ext
Import-Module (Join-Path $root 'PhpManager/PhpManager.psm1') -ErrorAction Stop
$startup=Get-PhpIniKey -Key display_startup_errors -Path "$root/php.ini"
New-Item evidence -ItemType Directory -Force | Out-Null
$runtime=php -d display_errors=0 -d display_startup_errors=0 -d log_errors=0 -r 'echo json_encode(["php"=>PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION,"redis"=>phpversion("redis"),"loaded"=>extension_loaded("redis")]);' 2>$null | ConvertFrom-Json
$data=[ordered]@{
 phase=$Phase; runtime=$runtime; outcome=$env:SETUP_OUTCOME; startup=$startup
 files=@(Get-ChildItem $ext -File -Filter '*redis*' | ForEach-Object { @{name=$_.Name;size=$_.Length;hash=(Get-FileHash $_.FullName).Hash} })
 ini=@(Get-Content "$root/php.ini" | Where-Object { $_ -match '^((zend_)?extension=.*redis|display(_startup)?_errors)' })
}
$data | ConvertTo-Json -Depth 6 | Tee-Object "evidence/$Phase.json"
if ($runtime.redis -ne $ExpectedVersion -or -not $runtime.loaded) {throw "Expected Redis $ExpectedVersion, got $($runtime.redis)"}
if ($ExpectedStartup -eq 'unset') {
 if ($null -ne $startup) {throw "Startup-error key was not removed: $startup"}
} elseif ($ExpectedStartup -ne '' -and $startup -ne $ExpectedStartup) {
 throw "Startup-error setting changed: $startup, expected $ExpectedStartup"
}
$failed=($Phase -eq 'rollback' -or ($Phase -eq 'after' -and $env:OUTAGE -eq 'true'))
if ($failed -and $env:SETUP_OUTCOME -ne 'failure') {throw 'The unavailable installation did not fail as expected'}
if (-not $failed -and $env:SETUP_OUTCOME -and $env:SETUP_OUTCOME -ne 'success') {throw 'Installation unexpectedly failed'}
$active=($data.files | Where-Object name -eq 'php_redis.dll').hash
$cached=($data.files | Where-Object name -eq "redis-$ExpectedVersion").hash
if (-not $active -or $active -ne $cached) {throw 'Loaded DLL does not match its versioned cache'}
if ($Phase -eq 'after' -and $env:OUTAGE -eq 'true') {
 $previous=Get-Content evidence/before.json -Raw | ConvertFrom-Json
 $old=($previous.files | Where-Object name -eq 'php_redis.dll').hash
 if ($active -ne $old) {throw 'Rollback did not restore the original working DLL'}
}
