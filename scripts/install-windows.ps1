param([Parameter(Mandatory=$true)][string]$Archive,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference = 'Stop'
# Same ZIP installation used by the Windows builder; configuration follows setup-php.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
Copy-Item (Join-Path $Destination 'php.ini-production') (Join-Path $Destination 'php.ini')
$ini = Join-Path $Destination 'php.ini'
Add-Content $ini @"
date.timezone=UTC
default_charset=UTF-8
extension_dir="$Destination\ext"
"@
foreach ($name in @('curl','mbstring','openssl','pdo_sqlite','sqlite3','zip')) {
    $dll = Join-Path $Destination "ext\php_$name.dll"
    if (Test-Path $dll) { Add-Content $ini "extension=`"$dll`"" }
}
$opcache = Join-Path $Destination 'ext\php_opcache.dll'
if (Test-Path $opcache) { Add-Content $ini "zend_extension=`"$opcache`"" }
Add-Content $ini 'opcache.enable_cli=1'
Write-Host "Installed exact archive at $Destination; using Windows-2022 VC runtimes."
