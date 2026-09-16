param([string]$Phase, [string]$Scenario)
$ErrorActionPreference = 'Stop'
$ext = (php -r 'echo ini_get("extension_dir");').Trim()
$phpRoot = Split-Path (Get-Command php).Source
New-Item evidence -ItemType Directory -Force | Out-Null
if ($Phase -eq 'seed') {
  foreach ($v in @('6.1.0', '6.2.0')) {
    $dir = Join-Path $env:RUNNER_TEMP "redis-$v"
    $zip = "$dir.zip"
    Invoke-WebRequest "https://downloads.php.net/~windows/pecl/releases/redis/$v/php_redis-$v-8.3-nts-vs16-x64.zip" -OutFile $zip
    Expand-Archive $zip $dir -Force
    $dll = Get-ChildItem $dir -Recurse -Filter php_redis.dll | Select-Object -First 1
    if (!$dll) { throw "Missing Redis $v DLL" }
    Copy-Item $dll.FullName "$ext/redis-$v" -Force
  }
  $initial = if ($Scenario -eq 'switch') { '6.1.0' } else { '6.2.0' }
  Copy-Item "$ext/redis-$initial" "$ext/php_redis.dll" -Force
  Add-Content "$phpRoot/php.ini" 'extension=redis'
  $actual = (php -r 'echo phpversion("redis");').Trim()
  if ($actual -ne $initial) { throw "Fixture expected $initial, got $actual" }
  if ($Scenario -eq 'wrong-version') {
    Copy-Item "$ext/redis-6.1.0" "$ext/redis-6.2.0" -Force
  } elseif ($Scenario -eq 'corrupt') {
    [IO.File]::WriteAllText("$ext/redis-6.2.0", 'Truncated cache binary')
  } else {
    Remove-Item "$ext/redis-6.2.0" -Force
  }
}
$data = [ordered]@{
  phase = $Phase
  scenario = $Scenario
  action = $env:ACTION_REF
  runtime = (php -d display_errors=0 -r 'echo json_encode(["version"=>phpversion("redis"),"loaded"=>extension_loaded("redis")]);' 2>$null | ConvertFrom-Json)
  files = @(Get-ChildItem $ext -Filter '*redis*' | ForEach-Object { @{name=$_.Name; size=$_.Length; sha256=(Get-FileHash $_.FullName).Hash} })
  ini = @(Get-Content "$phpRoot/php.ini" | Where-Object { $_ -match 'redis' })
}
$data | ConvertTo-Json -Depth 6 | Tee-Object "evidence/$Phase.json"
if ($Phase -eq 'verify' -and $data.runtime.version -ne '6.2.0') { throw "Requested Redis 6.2.0, got $($data.runtime.version)" }
if ($Phase -eq 'final' -and $data.runtime.version -ne '6.1.0') { throw "Requested Redis 6.1.0, got $($data.runtime.version)" }
