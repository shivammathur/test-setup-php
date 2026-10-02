param([Parameter(Mandatory)][string]$Php, [Parameter(Mandatory)][string]$Vs, [Parameter(Mandatory)][string]$Arch, [Parameter(Mandatory)][string]$Mode)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item reports, packages, deps, build -ItemType Directory -Force | Out-Null
$matrix = Get-Content native-matrix.json -Raw | ConvertFrom-Json
$lane = @($matrix.include | Where-Object { $_.php -eq $Php -and $_.arch -eq $Arch })
if ($lane.Count -ne 1) { throw 'Ambiguous native matrix lane' }
$lane = $lane[0]
$expected = Get-Content expected-manifests.json -Raw | ConvertFrom-Json -AsHashtable
$base = 'https://downloads.php.net/~windows'

foreach ($library in @('libpng', 'cairo', 'pango', 'librrd')) {
    $item = $lane.libraries.$library
    $destination = "packages/$library"
    New-Item $destination -ItemType Directory -Force | Out-Null
    if ($Mode -eq 'candidate') {
        $run = gh api "repos/winlibs/winlib-builder/actions/runs/$($item.run)" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $run.conclusion -ne 'success') { throw "Unaccepted $library run" }
        $artifacts = gh api "repos/winlibs/winlib-builder/actions/runs/$($item.run)/artifacts" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Artifact metadata request failed' }
        $selected = @($artifacts.artifacts | Where-Object { $_.name -eq $item.artifact -and -not $_.expired -and $_.size_in_bytes -gt 0 })
        if ($selected.Count -ne 1) { throw "Expected one $($item.artifact)" }
        $selected[0] | ConvertTo-Json -Depth 30 | Set-Content "reports/$library-artifact.json"
        gh run download $item.run -R winlibs/winlib-builder -n $item.artifact -D $destination
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $library" }
    } else {
        $url = if ($library -eq 'libpng') { "$base/php-sdk/deps/$Vs/$Arch/$($item.artifact).zip" } else { "$base/pecl/deps/$($item.artifact).zip" }
        Invoke-WebRequest $url -OutFile "$destination.zip"
        Expand-Archive "$destination.zip" -DestinationPath $destination
        "$url $((Get-FileHash "$destination.zip" -Algorithm SHA256).Hash)" | Set-Content "reports/$library-canonical.txt"
    }
    $root = (Resolve-Path $destination).Path
    $manifest = $expected[$item.artifact]
    if (!$manifest) { throw "Missing accepted manifest for $($item.artifact)" }
    $actual = @{}
    foreach ($file in Get-ChildItem $root -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        $actual[$relative] = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($actual.Count -ne $manifest.Count) { throw "File count differs: $library" }
    foreach ($name in $manifest.Keys) {
        if ($actual[$name] -ne $manifest[$name]) { throw "File hash differs: $library/$name" }
    }
    Copy-Item "$destination/*" deps -Recurse -Force
}

$seriesUrl = "$base/php-sdk/deps/series/packages-$Php-$Vs-$Arch-staging.txt"
$series = (Invoke-WebRequest $seriesUrl).Content -split '[\r\n]+'
$series | Set-Content reports/series.txt
foreach ($library in @('glib', 'libffi', 'libiconv', 'libintl', 'libxml2', 'zlib')) {
    $selected = @($series | Where-Object { $_ -match "^$library-\d.*-$Vs-$Arch\.zip$" })
    if ($selected.Count -ne 1) { throw "Expected one $library dependency" }
    if ($selected[0] -ne $lane.dependencies.$library) { throw "Dependency changed since the accepted build: $library" }
    $zip = Join-Path $env:RUNNER_TEMP $selected[0]
    Invoke-WebRequest "$base/php-sdk/deps/$Vs/$Arch/$($selected[0])" -OutFile $zip
    Expand-Archive $zip -DestinationPath deps -Force
    "$($selected[0]) $((Get-FileHash $zip -Algorithm SHA256).Hash)" | Add-Content reports/dependency-zips.txt
}
Get-ChildItem deps -Recurse -File | Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content reports/input-sha256.json
$env:PATH = "$(Resolve-Path deps/bin);$env:PATH"
$include = "/I$((Resolve-Path deps/include/libpng16).Path)"
cl /nologo /W3 /O2 /MD $include tests/png-roundtrip.c /Febuild/png-shared.exe /link /LIBPATH:deps/lib libpng.lib
if ($LASTEXITCODE -ne 0) { throw 'Shared libpng client compilation failed' }
cl /nologo /W3 /O2 /MD /DPNG_STATIC $include tests/png-roundtrip.c /Febuild/png-static.exe /link /LIBPATH:deps/lib libpng_a.lib zlib_a.lib
if ($LASTEXITCODE -ne 0) { throw 'Static libpng client compilation failed' }
foreach ($variant in @('shared', 'static')) {
    & "build/png-$variant.exe" | Tee-Object "reports/png-$variant.log"
    if ($LASTEXITCODE -ne 0) { throw "Packaged libpng $variant runtime failed" }
}
python tests/consumer-runtime.py | Tee-Object reports/consumer-runtime.log
if ($LASTEXITCODE -ne 0) { throw 'Consumer runtime tests failed' }
foreach ($dll in @('libpng.dll', 'cairo-2.dll', 'pango-1.0-0.dll', 'pangocairo-1.0-0.dll', 'librrd-8.dll')) {
    dumpbin /nologo /headers /dependents /exports "deps/bin/$dll" > "reports/$dll-dumpbin.txt"
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed: $dll" }
}

# Upstream Windows tests use the same release source and exact staged zlib.
cmake -S libpng-src -B build/upstream -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DPNG_TESTS=ON "-DZLIB_LIBRARY:FILEPATH=$((Resolve-Path deps/lib/zlib_a.lib).Path)" "-DZLIB_INCLUDE_DIR:PATH=$((Resolve-Path deps/include).Path)"
if ($LASTEXITCODE -ne 0) { throw 'Upstream CMake configuration failed' }
cmake --build build/upstream --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Upstream test compilation failed' }
ctest --test-dir build/upstream --no-tests=error --output-on-failure --parallel 4 --output-junit "$(Resolve-Path reports)/ctest.xml" | Tee-Object reports/ctest.log
if ($LASTEXITCODE -ne 0) { throw 'Upstream Windows tests failed' }

foreach ($fixture in @('ch1n3p04.png', 'ch2n3p08.png')) {
    & build/png-shared.exe "libpng-src/contrib/testpngs/$fixture"
    if ($LASTEXITCODE -ne 0) { throw "hIST regression failed: $fixture" }
}
