param([string]$Phase, [string]$ExpectedPhp, [string]$ExpectedTs)
$ErrorActionPreference='Stop'
$root=Split-Path (Get-Command php).Source
$ext=Join-Path $root ext
$runtime=php -d display_errors=0 -d display_startup_errors=0 -r 'echo json_encode(["php"=>PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION,"ts"=>(bool)PHP_ZTS,"redis"=>phpversion("redis")]);' 2>$null | ConvertFrom-Json
Import-Module PhpManager -ErrorAction Stop
$manager=Get-PhpExtension -Path $root | Where-Object Handle -eq 'redis'
New-Item evidence -ItemType Directory -Force | Out-Null
$data=[ordered]@{
  phase=$Phase; runtime=$runtime; state=$manager.State; action=$env:ACTION_REF; outcome=$env:SETUP_OUTCOME
  files=@(Get-ChildItem $ext -File -Filter '*redis*' | ForEach-Object { @{name=$_.Name; size=$_.Length; sha256=(Get-FileHash $_.FullName).Hash} })
  ini=@(Get-Content "$root/php.ini" | Where-Object {$_ -match '^\s*(zend_)?extension\s*=.*redis'})
}
$data | ConvertTo-Json -Depth 6 | Tee-Object "evidence/$Phase.json"
if ($runtime.php -ne $ExpectedPhp -or $runtime.ts -ne ($ExpectedTs -eq 'ts')) {throw 'Wrong PHP build'}
if ($runtime.redis -ne '6.2.0') {throw "Expected Redis 6.2.0, got $($runtime.redis)"}
if ($env:SETUP_OUTCOME -and $env:SETUP_OUTCOME -ne 'success') {throw 'setup-php failed'}

if ($manager.State -ne 'Enabled') {throw 'PhpManager does not report Redis as loaded'}
if ($Phase -eq 'returned') {
  $original=Get-Content evidence/before.json -Raw | ConvertFrom-Json
  $oldHash=($original.files | Where-Object name -eq 'php_redis.dll').sha256
  $newHash=($data.files | Where-Object name -eq 'php_redis.dll').sha256
  if ($newHash -ne $oldHash) {throw 'Returning to the original PHP build produced a different DLL'}
}
