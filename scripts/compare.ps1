param([string] $Vs, [string] $Arch)
$ErrorActionPreference = 'Stop'
$rows = @(Get-Content native-plan.json -Raw | ConvertFrom-Json | Where-Object { $_.vs -eq $Vs -and $_.arch -eq $Arch })
if ($rows.Count -ne 1) { throw 'Expected exactly one artifact plan' }
$row = $rows[0]
Invoke-WebRequest $row.baseline.url -OutFile published.zip
if ((Get-FileHash published.zip).Hash.ToLowerInvariant() -ne $row.baseline.sha256) { throw 'Published build hash changed' }
Expand-Archive published.zip -DestinationPath published
$hashes = @{}
foreach ($variant in @('published', 'patched', 'no_getenv')) {
    & cl /nologo /O2 /MD /W3 "/I$variant/include" tests/jpeg-bench.c /link "/LIBPATH:$variant/lib" libjpeg_a.lib "/OUT:$variant-bench.exe"
    if ($LASTEXITCODE) { throw "Benchmark linking failed for $variant" }
    $hashes[$variant] = (Get-FileHash "$variant/lib/libjpeg_a.lib").Hash.ToLowerInvariant()
}
$failures = @(Get-Content reports/build-failures.json -Raw | ConvertFrom-Json)
foreach ($variant in @('patched', 'no_getenv')) {
    & cl /nologo /O2 /MD /W3 /DEXPECT_JPEG_ABI=80 "/I$variant/include" tests/jpeg-consumer.c /link "/LIBPATH:$variant/lib" libjpeg_a.lib "/OUT:$variant-consumer.exe"
    if ($LASTEXITCODE) { throw "Consumer linking failed for $variant" }
    & "./$variant-consumer.exe"
    if ($LASTEXITCODE) { $failures += "$variant installed consumer failed" }
    & cl /nologo /O2 /MD /W3 "/I$variant-build" "/I$variant-src/src" "/I$variant-src/simd" tests/jpeg-behavior.c /link "/LIBPATH:$variant/lib" libjpeg_a.lib "/OUT:$variant-behavior.exe"
    if ($LASTEXITCODE) { throw "Behavior probe linking failed for $variant" }
    $probe = & "./$variant-behavior.exe" $variant
    if ($LASTEXITCODE) { $failures += "$variant behavior probe failed ($LASTEXITCODE)" }
    $probe | Set-Content "reports/$variant-behavior.json"
    $probe | Write-Host
}
@{
    vs=$Vs;arch=$Arch;published_url=$row.baseline.url;published_zip_sha256=$row.baseline.sha256
    library_sha256=$hashes;no_getenv_source='5e31759d415fef210f96b75bab79fe22aa77680a';patched_source='4324213718242f94b2df8ee099ef71283c076610'
    compiler=(Get-Item (Get-Command cl).Source).VersionInfo.FileVersion
    cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
    environment_entries=@(Get-ChildItem Env:).Count
} | ConvertTo-Json -Depth 6 | Set-Content reports/provenance.json
@{
    kind='native';variants=@{published="$PWD/published-bench.exe";patched="$PWD/patched-bench.exe";no_getenv="$PWD/no_getenv-bench.exe"}
    fixtures="$PWD/fixtures";rounds=15
} | ConvertTo-Json -Depth 4 | Set-Content reports/benchmark-config.json
python scripts/benchmark.py --config reports/benchmark-config.json --output reports/native-performance.json
$performanceStatus = $LASTEXITCODE
ConvertTo-Json -InputObject @($failures) | Set-Content reports/correctness-failures.json
if ($failures.Count) { throw ($failures -join '; ') }
if ($performanceStatus) { throw 'Performance differences exceeded the fixed regression threshold; inspect all comparisons' }
