$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$extension = $env:EXTENSION
$expected = $env:EXPECTED_VERSION
New-Item evidence -ItemType Directory -Force > $null
php -v | Tee-Object evidence/php-version.txt
php --ri $extension | Tee-Object evidence/extension-info.txt
php smoke.php | Tee-Object evidence/smoke.txt
$actual = php -r 'echo phpversion(getenv("EXTENSION"));'
if ($actual -ne $expected) { throw "Expected $expected, got $actual" }
"$extension-$($env:EXPECTED_STATE) resolved to $actual" | Set-Content evidence/resolved.txt
$phpDir = Split-Path (Get-Command php).Source
$extDir = php -r 'echo ini_get("extension_dir");'
if (![IO.Path]::IsPathRooted($extDir)) { $extDir = Join-Path $phpDir $extDir }
$dll = Join-Path $extDir "php_$extension.dll"
if (!(Test-Path $dll)) { throw "Missing DLL: $dll" }
$artifact = Join-Path $PWD "evidence/php_$extension.dll"
Copy-Item $dll $artifact
$bytes = [IO.File]::ReadAllBytes($artifact)
if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw 'Missing MZ signature' }
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x4550) { throw 'Missing PE signature' }
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$characteristics = [BitConverter]::ToUInt16($bytes, $peOffset + 22)
if ($machine -ne 0x8664 -or !($characteristics -band 0x2000)) { throw 'Expected an x64 DLL' }
(Get-Item $artifact).VersionInfo | Format-List | Out-File evidence/file-version.txt
'PE x64 DLL; PE and DLL characteristics verified.' | Set-Content evidence/file.txt
$hash = (Get-FileHash $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne (Get-FileHash $dll -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Artifact differs from installed DLL' }
"$hash  php_$extension.dll" | Set-Content evidence/SHA256SUMS
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$dumpbin = Get-ChildItem "$vs/VC/Tools/MSVC/*/bin/Hostx64/x64/dumpbin.exe" | Sort-Object FullName -Descending | Select-Object -First 1
if (!$dumpbin) { throw 'dumpbin was not found' }
& $dumpbin.FullName /HEADERS /DEPENDENTS $artifact | Out-File evidence/dependencies.txt
$phpOptions = @('-n')
$loadDirective = if ($extension -eq 'xdebug') { 'zend_extension' } else { 'extension' }
if ($extension -eq 'xdebug') { $phpOptions += @('-d', 'xdebug.mode=coverage') }
$dependencies = @(php -r '$extension = new ReflectionExtension(getenv("EXTENSION")); foreach ($extension->getDependencies() as $name => $type) { if (extension_loaded($name)) { echo $name, PHP_EOL; } }')
foreach ($dependency in $dependencies) {
  $builtin = php -n -r 'echo extension_loaded($argv[1]) ? "yes" : "no";' $dependency
  if ($builtin -ne 'yes') {
    $dependencyDll = Join-Path $extDir "php_$dependency.dll"
    if (!(Test-Path $dependencyDll)) { throw "Missing dependency: $dependencyDll" }
    $phpOptions += @('-d', "extension=$dependencyDll")
  }
}
php @phpOptions -d "${loadDirective}=$artifact" smoke.php | Tee-Object evidence/smoke-isolated.txt
if ($extension -eq 'vld') {
  php -d opcache.enable_cli=0 opcode.php | Tee-Object evidence/executed.txt
  if ((Get-Content evidence/executed.txt -Raw).Trim() -ne 'EXECUTED-42') { throw 'Normal execution failed' }
  php @phpOptions -d "extension=$artifact" -d vld.active=1 -d vld.execute=0 -d vld.dump_paths=0 opcode.php > evidence/suppressed-stdout.txt 2> evidence/opcodes.txt
  $opcodes = Get-Content evidence/opcodes.txt -Raw
  if ($opcodes -notmatch 'beta_probe' -or $opcodes -notmatch '\sADD\s' -or $opcodes -notmatch '\sRETURN\s') { throw 'Expected VLD opcodes missing' }
  if (Select-String '^EXECUTED-42$' evidence/suppressed-stdout.txt -Quiet) { throw 'VLD did not suppress execution' }
  'VLD disassembly and execution suppression passed.' | Tee-Object evidence/functionality.txt
}
