param([string]$Phase, [string]$ExpectedVersion)
$ErrorActionPreference = 'Stop'
$phpRoot = Split-Path (Get-Command php).Source
$ext = Join-Path $phpRoot ext
$active = Join-Path $ext php_redis.dll
$marker = Join-Path $ext versioned-cache-evidence.json
New-Item evidence -ItemType Directory -Force | Out-Null
function Get-Hash([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash }
function Get-Runtime {
  $value = php -d display_errors=0 -d display_startup_errors=0 -r 'echo json_encode(["version"=>phpversion("redis"),"loaded"=>extension_loaded("redis"),"ts"=>(bool)PHP_ZTS]);' 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'PHP failed to run' }
  $value | ConvertFrom-Json
}
if ($Phase -eq 'initial') {
  $runtime = Get-Runtime
  if ($runtime.version -ne '6.1.0') { throw 'Initial Redis 6.1.0 is missing' }
  $metadata = @{
    run=$env:GITHUB_RUN_ID; action=$env:ACTION_SHA; ts=$env:PHPTS
    hashes=@{'6.1.0'=(Get-Hash $active)}
  }
  $metadata | ConvertTo-Json -Depth 6 | Set-Content $marker
  # Exercise replacement of an installed extension that has no versioned cache yet.
  Remove-Item "$ext/redis-6.1.0" -Force
} else {
  $metadata = Get-Content $marker -Raw | ConvertFrom-Json -AsHashtable
  if ($metadata.run -ne $env:GITHUB_RUN_ID -or $metadata.action -ne $env:ACTION_SHA -or $metadata.ts -ne $env:PHPTS) { throw 'Unexpected cache provenance' }
  if ($Phase -eq 'upgraded') {
    $metadata.hashes['6.2.0'] = Get-Hash $active
    $metadata | ConvertTo-Json -Depth 6 | Set-Content $marker
  }
  foreach ($version in @('6.1.0','6.2.0')) {
    if ((Get-Hash "$ext/redis-$version") -ne $metadata.hashes[$version]) { throw "Cached Redis $version differs from the installed binary" }
  }
  if ($Phase -eq 'restored') {
    Remove-Item $active -Force
    if (Test-Path $active) { throw 'Failed to remove active DLL before cache-only restore' }
  } else {
    if ((Get-Hash $active) -ne $metadata.hashes[$ExpectedVersion]) { throw "Active DLL does not match cache for $ExpectedVersion" }
  }
}
if ($Phase -eq 'rollback') {
  if ($env:INSTALL_OUTCOME -ne 'failure') { throw 'Unavailable version did not fail as expected' }
  if (Test-Path "$ext/redis-999.0.0") { throw 'Failed installation created a versioned cache' }
}
if (@(Get-ChildItem $ext -Filter 'php_redis*.dll').Count -ne [int]($Phase -ne 'restored')) { throw 'Unexpected active or backup DLLs' }
if (Get-ChildItem $ext -Filter '*.bak.dll') { throw 'Found a backup that PhpManager could scan' }
$ini = @(Get-Content "$phpRoot/php.ini" | Where-Object { $_ -match '^\s*(zend_)?extension\s*=.*redis' })
if ($ini -match 'redis\.bak') { throw 'php.ini references a backup DLL' }
$runtime = if ($Phase -eq 'restored') { $null } else { Get-Runtime }
if ($Phase -ne 'restored') {
  if ($runtime.version -ne $ExpectedVersion -or !$runtime.loaded) { throw "Wrong loaded Redis version: $($runtime.version), expected $ExpectedVersion" }
  if ($runtime.ts -ne ($env:PHPTS -eq 'ts')) { throw 'Wrong PHP thread safety' }
}
[ordered]@{
  phase=$Phase; runtime=$runtime; metadata=$metadata; ini=$ini
  files=@(Get-ChildItem $ext -File -Filter '*redis*' | ForEach-Object { @{name=$_.Name; size=$_.Length; sha256=(Get-Hash $_.FullName)} })
} | ConvertTo-Json -Depth 8 | Tee-Object "evidence/$Phase.json"
