param(
    [Parameter(Mandatory)][string] $PhpVersion,
    [Parameter(Mandatory)][ValidateSet('x86', 'x64')][string] $Arch,
    [Parameter(Mandatory)][ValidateSet('nts', 'ts')][string] $Ts
)
$ErrorActionPreference = 'Stop'
$compiler = if ($PhpVersion -match '^5\.[34]\.') { 'VC9' } else { 'VC11' }
$suffix = if ($Ts -eq 'nts') { "nts-Win32-$compiler-$Arch" } else { "Win32-$compiler-$Arch" }
$binaryName = "php-$PhpVersion-$suffix.zip"
New-Item evidence -ItemType Directory -Force | Out-Null
Get-ChildItem artifacts -File | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash)  $([IO.Path]::GetFileName($_.Path))" } | Set-Content evidence/checksums.txt
foreach ($archive in @("artifacts/$binaryName", "artifacts/php-debug-pack-$PhpVersion-$suffix.zip", "artifacts/php-devel-pack-$PhpVersion-$suffix.zip", "artifacts/php-test-pack-$PhpVersion.zip", "artifacts/php-$PhpVersion-src.zip")) {
    if (-not (Test-Path $archive)) { throw "Missing artifact: $archive" }
    & 7z t $archive
    if ($LASTEXITCODE -ne 0) { throw "Invalid archive: $archive" }
}
Expand-Archive "artifacts/$binaryName" -DestinationPath runtime
Expand-Archive "artifacts/php-devel-pack-$PhpVersion-$suffix.zip" -DestinationPath devel
Expand-Archive "artifacts/php-debug-pack-$PhpVersion-$suffix.zip" -DestinationPath debug
$major = $PhpVersion.Split('.')[0]
$core = if ($Ts -eq 'ts') { "php${major}ts" } else { "php$major" }
$headers = @(Get-ChildItem devel -Recurse -Filter php_version.h)
if ($headers.Count -ne 1 -or (Get-Content $headers[0] -Raw) -notmatch ('#define PHP_VERSION "' + [regex]::Escape($PhpVersion) + '"')) {
    throw 'Development pack PHP version does not match the binary'
}
if (-not (Get-ChildItem devel -Recurse -Filter "$core.lib")) { throw 'Core import library missing from development pack' }
$pdbNames = @('php', $core, 'php_intl')
if ([version]$PhpVersion -ge [version]'5.5') { $pdbNames += 'php_opcache' }
foreach ($name in $pdbNames) {
    $pdb = @(Get-ChildItem debug -Recurse -Filter "$name.pdb")
    if ($pdb.Count -ne 1) { throw "Missing debug symbols: $name.pdb" }
    $header = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($pdb[0].FullName), 0, 24)
    if ($header -ne 'Microsoft C/C++ MSF 7.00') { throw "Invalid PDB header: $name.pdb" }
}
$publicUrl = "https://downloads.php.net/~windows/releases/archives/$binaryName"
Invoke-WebRequest $publicUrl -OutFile public.zip
Expand-Archive public.zip -DestinationPath public
Get-FileHash public.zip | Format-List | Out-String | Set-Content evidence/public-checksum.txt
$runtime = (Resolve-Path runtime).Path
$public = (Resolve-Path public).Path
$env:PHP_INI_SCAN_DIR = ''
$env:PHPRC = ''
# Avoid SNMP MIB diagnostics unrelated to extension loading.
$env:MIBS = ';'
New-Item 'C:/usr/snmp/persist/mib_indexes' -ItemType Directory -Force | Out-Null
$comparisonFailures = [System.Collections.Generic.List[string]]::new()

function Assert-Same($Expected, $Actual, [string] $Label) {
    $diff = @(Compare-Object @($Expected | Sort-Object -Unique) @($Actual | Sort-Object -Unique))
    $diff | ConvertTo-Json | Set-Content "evidence/$Label-diff.json"
    if ($diff.Count) {
        $script:comparisonFailures.Add($Label)
        Write-Warning "$Label differ from public PHP: $($diff | Out-String)"
    }
}
function Invoke-CheckedPhp([string] $Root, [string[]] $Arguments, [string] $Label) {
    $output = & "$Root/php.exe" @Arguments 2>&1
    $code = $LASTEXITCODE
    $output | Out-String | Add-Content "evidence/$Label.txt"
    if ($code -ne 0 -or "$output" -match '(?im)(PHP (Warning|Fatal|Parse)|Unable to load|Unable to initialize|Startup:)') {
        throw "PHP validation failed: $Root $Arguments (exit $code): $output"
    }
    $output
}

# Install the compiler runtime needed by both the public and built packages.
if ($compiler -eq 'VC9') {
    Invoke-WebRequest 'https://download.microsoft.com/download/5/d/8/5d8c65cb-c849-4025-8e95-c3966cafd8ae/vcredist_x86.exe' -OutFile vcredist.exe
    $process = Start-Process (Resolve-Path vcredist.exe) -ArgumentList '/q','/norestart' -Wait -PassThru
    if ($process.ExitCode -notin @(0, 1638, 3010)) { throw "VC9 runtime installation failed: $($process.ExitCode)" }
}
if ($compiler -eq 'VC11') {
    Invoke-WebRequest "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_$Arch.exe" -OutFile vcredist.exe
    $process = Start-Process (Resolve-Path vcredist.exe) -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
    if ($process.ExitCode -notin @(0, 1638, 3010)) { throw "VC11 runtime installation failed: $($process.ExitCode)" }
}

$publicExtensions = @(Get-ChildItem "$public/ext/*.dll" | ForEach-Object { $_.Name.ToLowerInvariant() })
$builtExtensions = @(Get-ChildItem "$runtime/ext/*.dll" | ForEach-Object { $_.Name.ToLowerInvariant() })
$publicExtensions | Set-Content evidence/public-extensions.txt
$builtExtensions | Set-Content evidence/built-extensions.txt
Assert-Same $publicExtensions $builtExtensions 'extensions'
$getSapis = { param($root) Get-ChildItem "$root/php*" -File | Where-Object { $_.Extension -in @('.exe','.dll') } | ForEach-Object { $_.Name.ToLowerInvariant() } }
Assert-Same (& $getSapis $public) (& $getSapis $runtime) 'sapis'

$moduleCode = '$m=get_loaded_extensions(); sort($m); echo json_encode($m);'
$publicBuiltin = Invoke-CheckedPhp $public @('-n','-r',$moduleCode) 'public-builtin' | ConvertFrom-Json
$builtBuiltin = Invoke-CheckedPhp $runtime @('-n','-r',$moduleCode) 'built-builtin' | ConvertFrom-Json
Assert-Same $publicBuiltin $builtBuiltin 'builtin-modules'

# Supply the external Oracle client to both installations for OCI loading.
$oracleSuffix = if ($Arch -eq 'x86') { 'nt' } else { 'windows.x64' }
Invoke-WebRequest "https://download.oracle.com/otn_software/nt/instantclient/1932000/instantclient-basiclite-$oracleSuffix-19.32.0.0.0dbru.zip" -OutFile oracle.zip
Expand-Archive oracle.zip -DestinationPath oracle
$oracle = (Get-ChildItem oracle -Recurse -Filter oci.dll | Select-Object -First 1).Directory.FullName
if (-not $oracle) { throw 'Oracle runtime DLL missing' }
$env:PATH = "$oracle;$env:PATH"

# Firebird's client is external to the public PHP packages as well.
$firebirdArch = if ($Arch -eq 'x86') { 'Win32' } else { 'x64' }
Invoke-WebRequest "https://github.com/FirebirdSQL/firebird/releases/download/v4.0.4/Firebird-4.0.4.3010-0-$firebirdArch.zip" -OutFile firebird.zip
Expand-Archive firebird.zip -DestinationPath firebird
$firebird = (Get-ChildItem firebird -Recurse -Filter fbclient.dll | Select-Object -First 1).Directory.FullName
if (-not $firebird) { throw 'Firebird runtime DLL missing' }
$env:PATH = "$firebird;$env:PATH"

# SAP Open Client is not distributed with either PHP package. Compare its
# extension DLL, but record that runtime validation requires that proprietary client.
$runtimeExclusions = @('php_sybase_ct.dll')
@{extensions=$runtimeExclusions; reason='SAP Open Client runtime is not available on the runner; package parity is still checked'} | ConvertTo-Json | Set-Content evidence/runtime-exclusions.json

foreach ($root in @($public, $runtime)) {
    $ini = @('date.timezone=UTC', 'display_errors=stderr', 'log_errors=Off', "extension_dir=`"$root/ext`"", 'opcache.enable_cli=1')
    foreach ($dll in Get-ChildItem "$root/ext/php_*.dll" | Sort-Object Name) {
        if ($dll.Name -in $runtimeExclusions -or $dll.Name -eq 'php_oci8_11g.dll') { continue }
        if ($dll.Name -eq 'php_opcache.dll') { $ini += "zend_extension=`"$($dll.FullName)`"" }
        else { $ini += "extension=$($dll.Name)" }
    }
    Set-Content "$root/php.ini" $ini -Encoding ascii
}
# Both OCI8 variants export the same module. Validate each separately so
# duplicate loading does not hide a broken DLL.
foreach ($entry in @(@{Root=$public; Label='public'}, @{Root=$runtime; Label='built'})) {
    foreach ($variant in @('php_oci8.dll', 'php_oci8_11g.dll')) {
        Invoke-CheckedPhp $entry.Root @('-n', '-d', "extension_dir=$($entry.Root)/ext", '-d', "extension=$variant", '-r', 'if (!extension_loaded("oci8")) { exit(1); } echo oci_client_version(), PHP_EOL;') "$($entry.Label)-$variant" | Write-Host
    }
}
$publicModules = Invoke-CheckedPhp $public @('-c',"$public/php.ini",'-r',$moduleCode) 'public-modules' | ConvertFrom-Json
$builtModules = Invoke-CheckedPhp $runtime @('-c',"$runtime/php.ini",'-r',$moduleCode) 'built-modules' | ConvertFrom-Json
Assert-Same $publicModules $builtModules 'loaded-modules'
$env:EXPECTED_PHP_VERSION = $PhpVersion
$env:EXPECTED_PHP_ZTS = if ($Ts -eq 'ts') { '1' } else { '0' }
$env:EXPECTED_PHP_COMPILER = $compiler

$expectedMachine = if ($Arch -eq 'x64') { 0x8664 } else { 0x14c }
foreach ($file in Get-ChildItem $runtime -Recurse -File | Where-Object { $_.Extension -in @('.exe','.dll') }) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne $expectedMachine) { throw "Wrong PE machine: $($file.Name)" }
}

if ($compiler -eq 'VC11') {
    # Upstream PhpManager identifies PHP 5.x x64 as x86 from PHP_INT_SIZE.
    # Read the PE machine instead; preserve the compatibility patch as evidence.
    $patch = Join-Path $PSScriptRoot 'phpmanager-architecture.patch'
    & git -C phpmanager apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'PhpManager architecture patch no longer applies' }
    & git -C phpmanager apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'PhpManager architecture patch failed' }
    Copy-Item $patch evidence/
}
Import-Module ./phpmanager/PhpManager/PhpManager.psd1 -Force
$xdebugVersion = switch -Regex ($PhpVersion) { '^5\.3\.' { '2.2.7' } '^5\.4\.' { '2.4.1' } default { '2.5.5' } }
foreach ($entry in @(@{Root=$public; Label='public'}, @{Root=$runtime; Label='built'})) {
    $root = $entry.Root
    $label = $entry.Label
    $managerPhp = Get-Php -Path $root
    $managerPhp | ConvertTo-Json -Depth 5 | Set-Content "evidence/$label-phpmanager-detection.json"
    if ($managerPhp.Architecture -ne $Arch) { throw "PhpManager detected the wrong architecture for $label" }
    $env:EXPECTED_PHP_MODULES = if ($label -eq 'public') { $publicModules -join ',' } else { $builtModules -join ',' }
    foreach ($arguments in @(@('-v'), @('-m'), @('-r','phpinfo(INFO_GENERAL | INFO_CONFIGURATION | INFO_MODULES);'), @((Join-Path $PSScriptRoot 'smoke.php')))) {
        Invoke-CheckedPhp $root (@('-c',"$root/php.ini") + $arguments) "$label-runtime" | Write-Host
    }
    $cgiOutput = & "$root/php-cgi.exe" -n -v 2>&1
    $cgiOutput | Out-String | Set-Content "evidence/$label-cgi.txt"
    if ($LASTEXITCODE -ne 0 -or "$cgiOutput" -notmatch [regex]::Escape("PHP $PhpVersion")) { throw "CGI startup failed for $label" }
    # Exercise PhpManager's public download selection, DLL inspection, copying
    # and php.ini activation, rather than loading a manually supplied DLL.
    Install-PhpExtension -Extension xdebug -Version $xdebugVersion -Path $root -Verbose 4>&1 | Tee-Object "evidence/$label-phpmanager.txt" | Write-Host
    Get-ChildItem "$root/ext/*xdebug*.dll" | Get-FileHash -Algorithm SHA256 | Format-List | Out-String | Set-Content "evidence/$label-xdebug-checksum.txt"
    $env:EXPECTED_XDEBUG_VERSION = $xdebugVersion
    Invoke-CheckedPhp $root @('-c',"$root/php.ini",(Join-Path $PSScriptRoot 'xdebug.php')) "$label-xdebug" | Write-Host
    Invoke-CheckedPhp $root @('-c',"$root/php.ini",(Join-Path $PSScriptRoot 'smoke.php')) "$label-with-xdebug" | Write-Host
}
if ($comparisonFailures.Count) { throw "Public build parity failed: $($comparisonFailures -join ', ')" }
@{php=$PhpVersion; arch=$Arch; ts=$Ts; public=$publicUrl; extensionCount=$publicExtensions.Count; modules=$publicModules; runtimeExclusions=@($publicExtensions | Where-Object { $_ -in $runtimeExclusions }); phpManagerArchitecturePatch=($compiler -eq 'VC11'); xdebug=$xdebugVersion; result='passed'} | ConvertTo-Json -Depth 5 | Set-Content evidence/result.json
Write-Host "Public extension parity, smoke tests and PhpManager Xdebug installation passed"
