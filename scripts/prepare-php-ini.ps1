param(
    [Parameter(Mandatory)] [string] $PhpDirectory
)

$ErrorActionPreference = 'Stop'

$phpDirectoryPath = Resolve-Path -Path $PhpDirectory
$extensionDirectory = Join-Path $phpDirectoryPath 'ext'
$iniPath = Join-Path $phpDirectoryPath 'php.ini'

$extensionCandidates = @(
    'mbstring',
    'openssl',
    'curl',
    'fileinfo',
    'intl',
    'pdo_sqlite',
    'sqlite3',
    'zip',
    'sodium',
    'gd',
    'exif'
)

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('date.timezone=UTC')
$lines.Add('display_errors=1')
$lines.Add('error_reporting=E_ALL')
$lines.Add('memory_limit=1024M')
$lines.Add('default_socket_timeout=30')
$lines.Add('assert.exception=1')
$lines.Add("extension_dir=`"$extensionDirectory`"")

foreach ($extension in $extensionCandidates) {
    $dll = Join-Path $extensionDirectory "php_$extension.dll"
    if (Test-Path $dll) {
        $lines.Add("extension=$extension")
    }
}

$opcacheDll = Join-Path $extensionDirectory 'php_opcache.dll'
if (Test-Path $opcacheDll) {
    $lines.Add('zend_extension=opcache')
    $lines.Add('opcache.enable_cli=1')
}

Set-Content -Path $iniPath -Value $lines -Encoding ASCII
Write-Host "Wrote $iniPath"

