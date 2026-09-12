param([Parameter(Mandatory)][string]$InstallRoot)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path $InstallRoot).Path
$directory = Join-Path $env:RUNNER_TEMP ([guid]::NewGuid().ToString())
New-Item $directory -ItemType Directory | Out-Null
try {
    & cl /nologo /MD "/I$root/include" "$PSScriptRoot/icu-collation.c" "/Fe$directory/icu-collation.exe" "/Fo$directory/icu-collation.obj" /link "/LIBPATH:$root/lib" icuin.lib icuuc.lib icudt.lib
    if ($LASTEXITCODE -ne 0) { throw 'ICU regression harness compilation failed.' }
    $env:PATH = "$root/bin;$env:PATH"
    & "$directory/icu-collation.exe"
    if ($LASTEXITCODE -ne 0) { throw 'ICU-20715 artifact regression failed.' }
} finally {
    Remove-Item $directory -Recurse -Force
}
