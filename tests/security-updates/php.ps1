param(
    [Parameter(Mandatory)][string]$ArtifactsDirectory,
    [Parameter(Mandatory)][ValidateSet('x86', 'x64')][string]$Arch,
    [Parameter(Mandatory)][ValidateSet('nts', 'ts')][string]$Ts
)
$ErrorActionPreference = 'Stop'
$matches = @(Get-ChildItem $ArtifactsDirectory -Filter "php-*-$Arch.zip" | Where-Object {
    $_.Name -notmatch '^php-(devel-pack|debug-pack|test-pack)-' -and
    $_.Name -match "^php-.+?(-nts)?-Win32-v[sc]\d+-$Arch\.zip$" -and
    (($_.Name -match '-nts-') -eq ($Ts -eq 'nts'))
})
if ($matches.Count -ne 1) { throw "Expected one PHP binary archive, found $($matches.Count)" }
$root = Join-Path $env:RUNNER_TEMP "security-php-$Arch-$Ts"
Expand-Archive $matches[0].FullName -DestinationPath $root -Force
$config = Join-Path $root 'security-openssl.cnf'
@'
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
commonName = localhost
'@ | Set-Content $config
$env:OPENSSL_CONF = $config
$env:MIBDIRS = Join-Path $root 'mibs'
$env:MIBS = ''
New-Item -ItemType Directory -Path $env:MIBDIRS -Force | Out-Null
$arguments = @('-n', '-d', "extension_dir=$root\ext")
foreach ($extension in @('openssl', 'curl', 'ldap', 'pgsql', 'pdo_pgsql', 'gd', 'snmp')) {
    $arguments += @('-d', "extension=$extension")
}
$arguments += (Join-Path $PSScriptRoot 'php.php')
& "$root\php.exe" @arguments
if ($LASTEXITCODE -ne 0) { throw 'Security dependency runtime validation failed' }
