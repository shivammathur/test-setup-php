$ErrorActionPreference = 'Stop'
Invoke-Expression ((Get-Content ./fixtures/add_extensions.ps1 -Raw).Replace('>$null 2>&1', '2>&1 | Out-Host'))
$php_dir = Split-Path (Get-Command php).Source
$bin_dir = Split-Path (Get-Command pie -CommandType Application).Source
Import-Module (Join-Path $bin_dir 'PhpManager/PhpManager.psm1') -Force
$ext_dir = php -r 'echo ini_get("extension_dir");'
$installed = Get-Php -Path $php_dir
$version = '8.5'
$tick = '✓'
Function Add-Log($mark, $subject, $message) { Write-Host "$mark $subject $message" }
New-Item artifacts -ItemType Directory -Force > $null
Add-PieExtension phpstan_turbo phpstan/turbo:2.3.5
Add-PieExtension phpstan_turbo phpstan/turbo:2.3.5 -AllowSourceBuild $true
php --ri phpstan_turbo | Tee-Object artifacts/phpstan-turbo.txt
php -r 'exit(extension_loaded("phpstan_turbo") ? 0 : 1);'
if ($LASTEXITCODE -ne 0) { throw 'The extension is not loaded' }
$dll = Join-Path $ext_dir 'php_phpstan_turbo.dll'
Get-PhpExtension -Path $dll | Format-List * | Out-File artifacts/extension.txt
Copy-Item $dll artifacts/
