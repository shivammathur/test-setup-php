param([string]$Phase)
$ErrorActionPreference='Stop'
$root=Split-Path (Get-Command php).Source
$ext=Join-Path $root ext
New-Item evidence -ItemType Directory -Force | Out-Null
$runtime=php -d display_errors=0 -d display_startup_errors=0 -d log_errors=0 -r 'echo json_encode(["php"=>PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION,"redis"=>phpversion("redis"),"loaded"=>extension_loaded("redis")]);' 2>$null | ConvertFrom-Json
$data=[ordered]@{
 phase=$Phase; runtime=$runtime; outcome=$env:SETUP_OUTCOME
 files=@(Get-ChildItem $ext -File -Filter '*redis*' | ForEach-Object { @{name=$_.Name;size=$_.Length;hash=(Get-FileHash $_.FullName).Hash} })
 ini=@(Get-Content "$root/php.ini" | Where-Object { $_ -match '^((zend_)?extension=.*redis|display(_startup)?_errors)' })
}
$data | ConvertTo-Json -Depth 6 | Tee-Object "evidence/$Phase.json"
if ($Phase -eq 'first' -and $runtime.redis -ne '6.2.0') {throw 'First Redis installation failed'}
if ($Phase -eq 'before' -and $runtime.redis -ne '6.1.0') {throw 'Working Redis 6.1.0 was not loaded'}
if ($Phase -eq 'after') {
 $expected=if ($env:OUTAGE -eq 'true' -or $env:ACTION_NAME -eq 'release') {'6.1.0'} else {'6.2.0'}
 if ($runtime.redis -ne $expected -or -not $runtime.loaded) {throw "Expected Redis $expected to remain usable, got $($runtime.redis)"}
 if ($env:OUTAGE -ne 'true' -and $env:SETUP_OUTCOME -ne 'success') {throw 'Setup failed without an outage'}
}
