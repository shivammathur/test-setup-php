param([string] $VsInst, [string] $MsArch, [string] $MsTs, [string] $Sdk)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory reports -Force | Out-Null
$failures = @()
foreach ($variant in @('no_getenv', 'patched')) {
    git -C "$variant-src" apply --ignore-whitespace ../builder/patches/libjpeg.patch
    if ($LASTEXITCODE) { throw "Packaging patch failed for $variant" }
    git -C "$variant-src" diff | Set-Content "reports/$variant-source.diff"
    $expected = if ($variant -eq 'no_getenv') { '5e31759d415fef210f96b75bab79fe22aa77680a' } else { '4324213718242f94b2df8ee099ef71283c076610' }
    if ((git -C "$variant-src" rev-parse HEAD) -ne $expected) { throw 'Wrong source revision' }
    # The packaging patch must not change codec source in either checkout.
    if (@(git -C "$variant-src" diff --name-only) -ne 'simd/CMakeLists.txt') { throw 'Unexpected source change' }
    cmake -S "$variant-src" -B "$variant-build" -G "Visual Studio $VsInst" -A $MsArch -T $MsTs "-DCMAKE_SYSTEM_VERSION=$Sdk" "-DCMAKE_INSTALL_PREFIX=$PWD/$variant" -DCMAKE_POLICY_DEFAULT_CMP0141=NEW -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=ProgramDatabase -DWITH_JPEG8=1 -DWITH_CRT_DLL=1 -DENABLE_SHARED=0 -DWITH_TURBOJPEG=0 -DREQUIRE_SIMD=1
    if ($LASTEXITCODE) { throw "Configure failed for $variant" }
    if ($variant -eq 'no_getenv') {
        $flags = (Select-String -Path "$variant-build/CMakeCache.txt" -Pattern '^CMAKE_C_FLAGS:STRING=').Line.Split('=', 2)[1]
        cmake -S "$variant-src" -B "$variant-build" "-DCMAKE_C_FLAGS=$flags /DNO_GETENV"
        if ($LASTEXITCODE) { throw 'Could not add NO_GETENV' }
    }
    Copy-Item "$variant-build/CMakeCache.txt" "reports/$variant-CMakeCache.txt"
    cmake --build "$variant-build" --config RelWithDebInfo
    if ($LASTEXITCODE) { throw "Build failed for $variant" }
    ctest --test-dir "$variant-build" --build-config RelWithDebInfo --output-on-failure --parallel 2 --output-junit "$PWD/reports/$variant-ctest.xml"
    $ctestStatus = $LASTEXITCODE
    if ($ctestStatus) { $failures += "$variant upstream CTest failed ($ctestStatus)" }
    cmake --install "$variant-build" --config RelWithDebInfo
    if ($LASTEXITCODE) { throw "Install failed for $variant" }
}
ConvertTo-Json -InputObject @($failures) | Set-Content reports/build-failures.json
