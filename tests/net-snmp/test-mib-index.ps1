param([string]$InstallRoot = 'install', [string]$DependencyRoot = 'deps')
$ErrorActionPreference = 'Stop'
$install = (Resolve-Path $InstallRoot).Path
$dependencies = (Resolve-Path $DependencyRoot).Path
$directory = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item "$directory/mibs", "$directory/persistent" -ItemType Directory -Force | Out-Null
try {
    Copy-Item "$PSScriptRoot/SECURITY-TEST-MIB.txt" "$directory/mibs/"
    $executable = "$directory/mib-index.exe"
    $libraries = @('netsnmp.lib', 'libssl.lib', 'libcrypto.lib', 'advapi32.lib', 'ws2_32.lib', 'user32.lib')
    & cl /nologo /MD /DWIN32 "/I$install/include" "/I$dependencies/include" "$PSScriptRoot/mib-index.c" "/Fe$executable" "/Fo$directory/mib-index.obj" /link "/LIBPATH:$install/lib" "/LIBPATH:$dependencies/lib" @libraries
    if ($LASTEXITCODE -ne 0) { throw 'Unable to compile MIB regression test.' }
    $env:PATH = "$dependencies/bin;$env:PATH"
    $env:MIBDIRS = "$directory/mibs"
    $env:MIBS = 'ALL'
    $env:SNMP_PERSISTENT_DIR = "$directory/persistent"
    & $executable "$directory/mibs"
    if ($LASTEXITCODE -ne 0) { throw 'MIB parsing test failed.' }
    if (Test-Path "$directory/persistent/mib_indexes") { throw 'MIB index cache was created.' }
    New-Item "$directory/persistent/mib_indexes" -ItemType Directory | Out-Null
    $index = "$directory/persistent/mib_indexes/0"
    $sentinel = "DIR $directory/mibs`nSENTINEL`n"
    [IO.File]::WriteAllText($index, $sentinel)
    & $executable "$directory/mibs"
    if ($LASTEXITCODE -ne 0) { throw 'MIB parsing with an existing cache failed.' }
    if ([IO.File]::ReadAllText($index) -cne $sentinel) { throw 'Existing MIB index was overwritten.' }
    Write-Host 'PASS: MIB scans resolve OIDs, create no cache, and preserve existing index files.'
} finally {
    Remove-Item $directory -Recurse -Force
}
