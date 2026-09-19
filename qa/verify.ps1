param(
    [Parameter(Mandatory)][ValidateSet('x64', 'x86')][string]$Arch,
    [Parameter(Mandatory)][string]$Version,
    [switch]$Reference
)
$ErrorActionPreference = 'Stop'
New-Item validation -ItemType Directory -Force | Out-Null
$url = if ($Version -eq '0.3.18') {
    "https://downloads.php.net/~windows/pecl/deps/OpenBLAS-$Version-vs16-$Arch.zip"
} else {
    "https://github.com/OpenMathLib/OpenBLAS/releases/download/v$Version/OpenBLAS-$Version-$Arch.zip"
}
Invoke-WebRequest $url -OutFile validation/reference.zip -MaximumRetryCount 3
Expand-Archive validation/reference.zip validation/reference
$referenceDll = Get-ChildItem validation/reference -Filter libopenblas.dll -Recurse | Select-Object -First 1
if (-not $referenceDll) { throw 'Reference DLL missing' }
$referenceRoot = Split-Path (Split-Path $referenceDll.FullName)
if ($Version -ne '0.3.18') {
    # The official release header needs the same MSVC complex-type adaptation
    # already present in the historical PHP package; leave its DLL/lib untouched.
    $header = Join-Path $referenceRoot include/lapack.h
    $types = "#ifdef _MSC_VER`n#include <complex.h>`n#define lapack_complex_float _Fcomplex`n#define lapack_complex_double _Dcomplex`n#endif"
    (Get-Content $header -Raw).Replace('#include <stdlib.h>', "#include <stdlib.h>`n$types") | Set-Content $header
}
if ($Reference) { Copy-Item $referenceRoot install -Recurse }

function Get-Exports([string]$Dll) {
    $lines = & dumpbin.exe /nologo /exports $Dll
    if ($LASTEXITCODE) { throw "Cannot inspect exports: $Dll" }
    @($lines | ForEach-Object {
        if ($_ -match '^\s*(\d+)\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)') {
            "$($matches[1]) $($matches[2])"
        }
    } | Sort-Object)
}

function Get-Imports([string]$Dll) {
    $lines = & dumpbin.exe /nologo /dependents $Dll
    if ($LASTEXITCODE) { throw "Cannot inspect imports: $Dll" }
    @($lines | ForEach-Object {
        if ($_ -match '^\s+([\w.-]+\.dll)\s*$') { $matches[1].ToLowerInvariant() }
    } | Sort-Object -Unique)
}

function Build-Consumer([string]$Root, [string]$Name) {
    & cl.exe /nologo /W4 /WX /MD "/I$Root/include" qa/check.c `
        "/Fe:validation/$Name.exe" "/Fo:validation/$Name.obj" /link "/LIBPATH:$Root/lib" libopenblas.lib
    if ($LASTEXITCODE) { throw "MSVC consumer compile/link failed: $Name" }
}

function Run-Consumer([string]$Root, [string]$Name, [string]$Log) {
    $savedPath = $env:PATH
    try {
        # No MinGW compiler/runtime directory on PATH: the delivered DLL must
        # be self-contained apart from Windows' own runtime libraries.
        $env:PATH = (Resolve-Path "$Root/bin").Path + ";$env:SystemRoot\System32;$env:SystemRoot"
        $output = & "./validation/$Name.exe" 2>&1
        if ($LASTEXITCODE) { throw "Consumer failed ($LASTEXITCODE): $Name with $Root`n$output" }
        $output | Tee-Object "validation/$Log.txt" | Write-Host
        return @($output)[0]
    } finally { $env:PATH = $savedPath }
}

foreach ($file in @('bin/libopenblas.dll', 'lib/libopenblas.lib', 'include/cblas.h',
    'include/openblas_config.h', 'include/lapack.h', 'include/lapacke.h')) {
    if (-not (Test-Path "install/$file")) { throw "Missing package file: $file" }
}
$headers = & dumpbin.exe /nologo /headers install/bin/libopenblas.dll
if ($LASTEXITCODE) { throw 'Cannot inspect PE machine' }
$machine = if ($Arch -eq 'x64') { '8664 machine' } else { '14C machine' }
if (-not ($headers -match $machine)) { throw 'Wrong PE architecture' }
$imports = Get-Imports install/bin/libopenblas.dll
$imports | Set-Content validation/imports.txt
if (-not $imports.Count -or @($imports | Where-Object { $_ -notin @('kernel32.dll', 'msvcrt.dll') }).Count) {
    throw "Unexpected DLL runtime dependencies: $imports"
}
$exports = Get-Exports install/bin/libopenblas.dll
$exports | Set-Content validation/exports.txt
foreach ($symbol in @('cblas_dgemm', 'LAPACKE_dgetrf', 'LAPACKE_dgetri', 'LAPACKE_dgesdd',
    'LAPACKE_dpotrf', 'LAPACKE_dgeev', 'LAPACKE_dsyev', 'LAPACKE_zgesv', 'openblas_get_config')) {
    if (-not ($exports -match "^\d+ $symbol$")) { throw "Missing export: $symbol" }
}
if (-not $Reference) {
    $symbols = Get-Content install/share/build/OpenBLAS/symbols.txt -Raw
    foreach ($symbol in @('gfortran_runtime_error', 'quadmath_snprintf', 'pthread_create')) {
        if ($symbols -notmatch "\(sec\s+1\).*\s_*$symbol\b") {
            throw "The static runtime definition is missing from the DLL: $symbol"
        }
    }
    $linkMap = Get-Content install/share/build/OpenBLAS/link.map -Raw
    foreach ($library in @('libgfortran.a', 'libquadmath.a', 'libgcc.a')) {
        if ($linkMap -notmatch [regex]::Escape($library)) {
            throw "OpenBLAS did not statically link $library from the installed toolchain"
        }
    }
    # WinLibs provides the same winpthreads implementation under both names.
    if ($linkMap -notmatch 'lib(win)?pthread\.a\(') {
        throw 'OpenBLAS did not statically link winpthreads'
    }
}
Build-Consumer install check
$config = Run-Consumer install check native
if ($config -notmatch [regex]::Escape("OpenBLAS $Version ")) { throw "Wrong runtime version: $config" }

& {
    $referenceExports = Get-Exports $referenceDll.FullName
    $difference = Compare-Object $referenceExports $exports
    if ($difference) {
        $difference | Out-String | Set-Content validation/export-differences.txt
        throw "$Version exports/ordinals differ from the reference package"
    }
    if (Compare-Object (Get-Imports $referenceDll.FullName) $imports) {
        throw "$Version runtime DLL dependencies differ from the reference package"
    }
    # Compile against the old headers/import library and execute against both
    # old and new DLLs, then reverse the direction. This also checks ordinals.
    Build-Consumer $referenceRoot reference
    $referenceConfig = Run-Consumer $referenceRoot reference reference-original
    Run-Consumer install reference reference-consumer-new-dll | Out-Null
    Run-Consumer $referenceRoot check new-consumer-reference-dll | Out-Null
    if ($config -cne $referenceConfig) { throw "Runtime configuration differs: $config / $referenceConfig" }
    @(
        'PASS: identical exports and ordinals, runtime dependencies and OpenBLAS configuration.',
        'PASS: old/new headers and import libraries work with both DLLs; numeric and complex tests pass.',
        "Reference: $url",
        "Reference SHA256: $((Get-FileHash $referenceDll.FullName).Hash)",
        "Rebuilt SHA256: $((Get-FileHash install/bin/libopenblas.dll).Hash)",
        'Binary hashes are recorded separately; ABI compatibility is not a claim of byte-identical output.'
    ) | Tee-Object validation/comparison.txt | Write-Host
}
