param(
    [Parameter(Mandatory)][string] $PhpVersion,
    [Parameter(Mandatory)][ValidateSet('x86', 'x64')][string] $Arch,
    [Parameter(Mandatory)][ValidateSet('nts', 'ts')][string] $Ts
)
$ErrorActionPreference = 'Stop'
$compiler = if ($PhpVersion.StartsWith('5.6.')) { 'VC11' } else { 'VC14' }
$suffix = if ($Ts -eq 'nts') { "nts-Win32-$compiler-$Arch" } else { "Win32-$compiler-$Arch" }
$binary = "artifacts/php-$PhpVersion-$suffix.zip"
New-Item evidence -ItemType Directory -Force | Out-Null
Get-ChildItem artifacts -File | Get-FileHash -Algorithm SHA256 | Format-Table -AutoSize | Out-String | Tee-Object evidence/checksums.txt
foreach ($archive in @($binary, "artifacts/php-debug-pack-$PhpVersion-$suffix.zip", "artifacts/php-devel-pack-$PhpVersion-$suffix.zip", "artifacts/php-$PhpVersion-src.zip")) {
    if (-not (Test-Path $archive)) { throw "Missing artifact: $archive" }
    & 7z t $archive
    if ($LASTEXITCODE -ne 0) { throw "Invalid archive: $archive" }
}
Expand-Archive $binary -DestinationPath runtime
$runtime = (Resolve-Path runtime).Path
foreach ($file in @('php.exe', 'php-cgi.exe', 'php-win.exe', 'php.ini-development', 'php.ini-production', 'ext/php_opcache.dll')) {
    if (-not (Test-Path (Join-Path $runtime $file))) { throw "Missing runtime file: $file" }
}

# Loading an independently built Zend extension verifies compatibility with the
# published compiler, PHP API, architecture and thread-safety ABI together.
$series = ($PhpVersion.Split('.')[0..1] -join '.')
$xdebugPackage = "php_xdebug-2.5.5-$series-$Ts-$($compiler.ToLower())-$Arch.zip"
Invoke-WebRequest "https://downloads.php.net/~windows/pecl/releases/xdebug/2.5.5/$xdebugPackage" -OutFile xdebug.zip
Expand-Archive xdebug.zip -DestinationPath xdebug
$xdebug = @(Get-ChildItem xdebug -Recurse -Filter 'php_xdebug*.dll')
if ($xdebug.Count -ne 1) { throw 'Expected one published Xdebug DLL' }
$output = & "$runtime/php.exe" -n -d "zend_extension=$($xdebug[0].FullName)" -r 'if (phpversion("xdebug") !== "2.5.5") { exit(1); } echo "Published Xdebug 2.5.5 loaded successfully\n";' 2>&1
$code = $LASTEXITCODE
$output | Tee-Object evidence/xdebug.txt
if ($code -ne 0 -or "$output" -match '(?i)(Warning|Fatal|Unable|Startup:)') { throw 'Published Xdebug ABI check failed' }
$bytes = [IO.File]::ReadAllBytes("$runtime/php.exe")
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$expectedMachine = if ($Arch -eq 'x64') { 0x8664 } else { 0x14c }
if ($machine -ne $expectedMachine) { throw "Wrong PE machine: $machine" }
$ini = @('date.timezone=UTC', 'display_errors=stderr', 'log_errors=Off', "extension_dir=`"$runtime/ext`"", 'opcache.enable_cli=1')
foreach ($dll in Get-ChildItem "$runtime/ext/php_*.dll" | Sort-Object Name) {
    if ($dll.Name -match '^php_(oci8.*|pdo_oci|pdo_firebird|interbase|snmp)\.dll$') { continue }
    if ($dll.Name -eq 'php_opcache.dll') {
        $ini += "zend_extension=`"$($dll.FullName)`""
    } else {
        $ini += "extension=$($dll.Name)"
    }
}
Set-Content "$runtime/php.ini" $ini -Encoding ascii
$env:PHP_INI_SCAN_DIR = ''
$env:EXPECTED_PHP_VERSION = $PhpVersion
$env:EXPECTED_PHP_ZTS = if ($Ts -eq 'ts') { '1' } else { '0' }
$env:EXPECTED_PHP_COMPILER = $compiler
$requiredModules = @('bz2','com_dotnet','curl','enchant','ftp','gd','intl','ldap','mbstring','mysqli','mysqlnd','odbc','openssl','PDO','pdo_mysql','PDO_ODBC','pdo_pgsql','pdo_sqlite','pgsql','SimpleXML','sqlite3','xml','xmlreader','xmlwriter','xsl','Zend OPcache','zip','zlib','mcrypt')
$env:EXPECTED_PHP_MODULES = $requiredModules -join ','
foreach ($arguments in @(@('-v'), @('-m'), @('-i'), @((Join-Path $PSScriptRoot 'smoke.php')))) {
    $output = & "$runtime/php.exe" -c "$runtime/php.ini" @arguments 2>&1
    $code = $LASTEXITCODE
    $output | Tee-Object -FilePath evidence/runtime.txt -Append
    if ($code -ne 0 -or "$output" -match '(?im)(PHP (Warning|Fatal|Parse)|Unable to load|Unable to initialize|Startup:)') {
        throw "PHP validation failed: $arguments (exit $code)"
    }
}
