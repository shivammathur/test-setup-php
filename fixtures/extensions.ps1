$ErrorActionPreference = 'Stop'
$src = Join-Path $env:GITHUB_WORKSPACE 'setup-php\src'
. "$src\scripts\extensions\add_extensions.ps1"
$php = (Get-Command php -CommandType Application | Select-Object -First 1).Source
$php_dir = Split-Path $php
$bin_dir = Split-Path ((Get-Command phpstan -CommandType Application | Select-Object -First 1).Source)
$ext_dir = & $php -r 'echo ini_get("extension_dir");'
$installed = Get-Php -Path $php_dir
$tick = 'ok'
Function Add-Log($mark, $subject, $message) { Write-Host "$mark $subject $message" }
Function Get-File($Url, $OutFile) { Invoke-WebRequest -Uri $Url -OutFile $OutFile }
& $php fixtures/resolver-check.php (Join-Path $env:GITHUB_WORKSPACE 'setup-php') "$bin_dir\composer"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Add-PieExtension fastjson latest $false
& $php --ri fastjson
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Copy-Item "$ext_dir\php_fastjson.dll" artifacts/
