$ErrorActionPreference = 'Stop'
. "$env:GITHUB_WORKSPACE\setup-php\src\scripts\run.ps1"
Set-Location $env:GITHUB_WORKSPACE
& php --ri phpstan_turbo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& php -d disable_classes=Phar fixtures/resolver.php "$env:GITHUB_WORKSPACE\setup-php"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Add-PieExtension fastjson latest $false
& php --ri fastjson
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Copy-Item "$ext_dir\php_fastjson.dll" artifacts/
try {
  Add-PieExtension apcu latest $true
  throw 'Source-only APCu should not have been built on Windows'
} catch {
  if ($_.Exception.Message -notlike '*source builds are not supported on Windows*') { throw }
  Write-Host 'Windows source-only release correctly reported as unsupported.'
}
