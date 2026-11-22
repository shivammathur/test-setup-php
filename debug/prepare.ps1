param([string] $PhpSeries, [string] $ThreadSafety)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = $env:GITHUB_WORKSPACE
$evidence = Join-Path $root 'evidence'
New-Item -ItemType Directory -Force $evidence | Out-Null
$builds = @(Get-ChildItem (Join-Path $root 'build') -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'php-bin/php.exe') })
if ($builds.Count -ne 1) { throw "Expected one PHP build, found $($builds.Count)" }
$build = $builds[0].FullName
$phpDir = Join-Path $build 'php-bin'
$php = Join-Path $phpDir 'php.exe'
$release = if ($ThreadSafety -eq 'ts') { 'x64/Release_TS' } else { 'x64/Release' }
$dll = Join-Path $build "$release/php_pdo_oci.dll"
$pdb = Join-Path $build "$release/php_pdo_oci.pdb"
if (!(Test-Path $dll) -or !(Test-Path $pdb)) { throw 'The built DLL or matching PDB is missing' }
$runtime = Join-Path $evidence 'extension'
New-Item -ItemType Directory -Force $runtime | Out-Null
Copy-Item $dll, $pdb $runtime
$dll = Join-Path $runtime 'php_pdo_oci.dll'
$version = (& $php -n -r 'echo PHP_VERSION;').Trim()
$actualTs = (& $php -n -r 'echo PHP_ZTS ? "ts" : "nts";').Trim()
if (!$version.StartsWith("$PhpSeries.") -or $actualTs -ne $ThreadSafety) { throw "Wrong PHP: $version $actualTs" }
$vs = if ($PhpSeries -eq '8.6') { 'vs18' } else { 'vs17' }
$tsPart = if ($ThreadSafety -eq 'nts') { 'nts-Win32' } else { 'Win32' }
$debugName = "php-debug-pack-$version-$tsPart-$vs-x64.zip"
$debugZip = Join-Path $env:RUNNER_TEMP $debugName
& curl.exe -fL --retry 4 -o $debugZip "https://windows.php.net/downloads/releases/$debugName"
if ($LASTEXITCODE -ne 0) {
    & curl.exe -fL --retry 4 -o $debugZip "https://windows.php.net/downloads/releases/archives/$debugName"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot download matching PHP symbols' }
}
$symbols = Join-Path $evidence 'symbols'
Expand-Archive $debugZip $symbols -Force
$cdb = "${env:ProgramFiles(x86)}/Windows Kits/10/Debuggers/x64/cdb.exe"
if (!(Test-Path $cdb)) { throw "CDB is missing: $cdb" }
$source = Join-Path $root 'php-src'
& git clone --depth 1 --branch "php-$version" https://github.com/php/php-src.git $source
if ($LASTEXITCODE -ne 0) { throw 'Cannot download matching PHP source/tests' }
Import-Module (Join-Path $root 'builder/extension/BuildPhpExtension/BuildPhpExtension.psd1') -Force
$global:oracleHome = 'C:\oracle\product\21c\dbhomeXE'
Push-Location $build
try { Add-OciDB } finally { Pop-Location }
# Use the same Instant Client that the extension builder downloaded, ahead of XE's client.
$oci = Join-Path (Split-Path $build) 'deps'
if (!(Test-Path (Join-Path $oci 'oci.dll'))) { throw 'Builder Instant Client is missing' }
$env:PATH = "$oci;$phpDir;$env:PATH"
$phpArgs = @('-n', '-d', "extension=$dll", '-d', 'opcache.enable_cli=0')
& $php @phpArgs -v | Set-Content (Join-Path $evidence 'php-version.txt')
& $php @phpArgs -i | Set-Content (Join-Path $evidence 'php-info.txt')
if ($LASTEXITCODE -ne 0) { throw 'Built extension does not load' }
Get-FileHash $php, $dll, (Join-Path $oci 'oci.dll') | ConvertTo-Json | Set-Content (Join-Path $evidence 'binary-hashes.json')
Get-Item (Join-Path $oci 'oci.dll') | Select-Object FullName, @{n='FileVersion';e={$_.VersionInfo.FileVersion}} | ConvertTo-Json | Set-Content (Join-Path $evidence 'oracle-client.json')
[ordered]@{ php=$php; dll=$dll; cdb=$cdb; symbols=$symbols; source=$source; build=$build; oci=$oci; version=$version; ts=$ThreadSafety } |
    ConvertTo-Json | Set-Content (Join-Path $evidence 'paths.json')
