param([string] $VsInst, [string] $MsArch, [string] $MsTs, [string] $Sdk)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory reports -Force | Out-Null
$failures = @()
foreach ($variant in @('crt','ob3','startup')) {
    Copy-Item candidate-src "$variant-src" -Recurse
    if ((git -C "$variant-src" rev-parse HEAD) -ne '85e7e7b3adf7d17fabd57a1b7f8953c3815f157c') { throw 'Wrong source revision' }
    git -C "$variant-src" apply --ignore-whitespace ../builder/patches/libjpeg.patch
    if ($LASTEXITCODE) { throw "Packaging patch failed for $variant" }
    if ($variant -eq 'startup') {
        git -C "$variant-src" apply ../tests/startup-getenv.patch
        if ($LASTEXITCODE) { throw 'Startup fast-path patch failed' }
    }
    git -C "$variant-src" diff | Set-Content "reports/$variant-source.diff"
    cmake -S "$variant-src" -B "$variant-build" -G "Visual Studio $VsInst" -A $MsArch -T $MsTs "-DCMAKE_SYSTEM_VERSION=$Sdk" "-DCMAKE_INSTALL_PREFIX=$PWD/$variant" -DCMAKE_POLICY_DEFAULT_CMP0141=NEW -DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=ProgramDatabase -DWITH_JPEG8=1 -DWITH_CRT_DLL=1 -DENABLE_SHARED=0 -DWITH_TURBOJPEG=0 -DREQUIRE_SIMD=1
    if ($LASTEXITCODE) { throw "Configure failed for $variant" }
    if ($variant -eq 'ob3') {
        $flags = (Select-String -Path "$variant-build/CMakeCache.txt" -Pattern '^CMAKE_C_FLAGS_RELWITHDEBINFO:STRING=').Line.Split('=',2)[1]
        if ($flags -notmatch '/Ob1') { throw "Unexpected optimization flags: $flags" }
        cmake -S "$variant-src" -B "$variant-build" "-DCMAKE_C_FLAGS_RELWITHDEBINFO=$($flags -replace '/Ob1','/Ob3')"
        if ($LASTEXITCODE) { throw 'Could not configure inlining' }
    }
    Copy-Item "$variant-build/CMakeCache.txt" "reports/$variant-CMakeCache.txt"
    cmake --build "$variant-build" --config RelWithDebInfo
    if ($LASTEXITCODE) { throw "Build failed for $variant" }
    ctest --test-dir "$variant-build" --build-config RelWithDebInfo --output-on-failure --parallel 2 --output-junit "$PWD/reports/$variant-ctest.xml"
    if ($LASTEXITCODE) { $failures += "$variant upstream CTest failed" }
    cmake --install "$variant-build" --config RelWithDebInfo
    if ($LASTEXITCODE) { throw "Install failed for $variant" }
}
ConvertTo-Json -InputObject @($failures) | Set-Content reports/build-failures.json
