param(
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\tests\com-local-server'
$output = [System.IO.Path]::GetFullPath($OutputDirectory)
$build = Join-Path $output 'build'
New-Item -Path $build -ItemType Directory -Force | Out-Null

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) {
    throw 'A Visual Studio installation with the x86 C++ tools was not found.'
}

$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvarsall.bat'
$environmentLines = & $env:ComSpec /d /s /c "`"$vcvars`" x86 >nul && set"
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to initialize the Visual Studio x86 build environment.'
}
foreach ($line in $environmentLines) {
    $separator = $line.IndexOf('=')
    if ($separator -gt 0) {
        [Environment]::SetEnvironmentVariable($line.Substring(0, $separator), $line.Substring($separator + 1), 'Process')
    }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )
    & $Name @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

Invoke-Tool midl.exe @(
    '/nologo',
    '/env', 'win32',
    '/h', (Join-Path $build 'comlocal.h'),
    '/iid', (Join-Path $build 'comlocal_i.c'),
    '/tlb', (Join-Path $output 'comlocal.tlb'),
    (Join-Path $source 'comlocal.idl')
)

Invoke-Tool cl.exe @(
    '/nologo', '/W4', '/EHsc', '/DUNICODE', '/D_UNICODE',
    "/I$build", "/Fo$(Join-Path $build 'comlocal.obj')", '/c',
    (Join-Path $source 'comlocal.cpp')
)
Invoke-Tool cl.exe @(
    '/nologo', '/W4', '/TC',
    "/Fo$(Join-Path $build 'comlocal_i.obj')", '/c',
    (Join-Path $build 'comlocal_i.c')
)
Invoke-Tool link.exe @(
    '/nologo',
    "/out:$(Join-Path $output 'comlocal.exe')",
    (Join-Path $build 'comlocal.obj'),
    (Join-Path $build 'comlocal_i.obj'),
    'ole32.lib', 'oleaut32.lib', 'advapi32.lib'
)

Get-Item (Join-Path $output 'comlocal.exe'), (Join-Path $output 'comlocal.tlb') |
    Select-Object FullName, Length, LastWriteTimeUtc
