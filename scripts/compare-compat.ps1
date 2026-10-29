param([string] $Vs, [string] $Arch)
$ErrorActionPreference = 'Stop'
$rows = @(Get-Content native-plan.json -Raw | ConvertFrom-Json | Where-Object { $_.vs -eq $Vs -and $_.arch -eq $Arch })
if ($rows.Count -ne 1) { throw 'Expected exactly one artifact plan' }
$row = $rows[0]
Invoke-WebRequest $row.baseline.url -OutFile published.zip
if ((Get-FileHash published.zip).Hash.ToLowerInvariant() -ne $row.baseline.sha256) { throw 'Published build hash changed' }
Expand-Archive published.zip -DestinationPath published
$hashes = @{}
foreach ($variant in @('published','crt','ob3','startup')) {
    & cl /nologo /O2 /MD /W3 "/I$variant/include" tests/jpeg-bench.c /link "/LIBPATH:$variant/lib" libjpeg_a.lib "/OUT:$variant-bench.exe"
    if ($LASTEXITCODE) { throw "Benchmark linking failed for $variant" }
    $hashes[$variant] = (Get-FileHash "$variant/lib/libjpeg_a.lib").Hash.ToLowerInvariant()
}
$failures = @(Get-Content reports/build-failures.json -Raw | ConvertFrom-Json)
foreach ($variant in @('crt','ob3','startup')) {
    foreach ($probe in @('jpeg-consumer','jpeg-behavior','review')) {
        & cl /nologo /O2 /MD /W3 /DEXPECT_JPEG_ABI=80 "/I$variant-build" "/I$variant-src/src" "/I$variant-src/simd" "tests/$probe.c" /link "/LIBPATH:$variant/lib" libjpeg_a.lib "/OUT:$variant-$probe.exe"
        if ($LASTEXITCODE) { throw "Probe linking failed for $variant $probe" }
        $output = & "./$variant-$probe.exe" $variant
        if ($LASTEXITCODE) { $failures += "$variant $probe failed ($LASTEXITCODE)" }
        $output | Set-Content "reports/$variant-$probe.json"
        $output | Write-Host
    }
    $env:JSIMD_FORCENONE = '1'; $env:JSIMD_NOHUFFENC = '1'; $env:JPEGMEM = '1234'
    try {
        $output = & "./$variant-review.exe" $variant inherited
        if ($LASTEXITCODE) { $failures += "$variant inherited controls failed ($LASTEXITCODE)" }
        $output | Set-Content "reports/$variant-inherited.json"
    } finally {
        Remove-Item Env:JSIMD_FORCENONE,Env:JSIMD_NOHUFFENC,Env:JPEGMEM
    }
}
@{
    vs=$Vs;arch=$Arch;published_url=$row.baseline.url;published_zip_sha256=$row.baseline.sha256
    library_sha256=$hashes;source='85e7e7b3adf7d17fabd57a1b7f8953c3815f157c'
    startup_patch_sha256=(Get-FileHash tests/startup-getenv.patch).Hash.ToLowerInvariant()
    compiler=(Get-Item (Get-Command cl).Source).VersionInfo.FileVersion
    cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
    environment_entries=@(Get-ChildItem Env:).Count
} | ConvertTo-Json -Depth 6 | Set-Content reports/provenance.json
$config = @{
    kind='native';variants=@{published="$PWD/published-bench.exe";crt="$PWD/crt-bench.exe";ob3="$PWD/ob3-bench.exe";startup="$PWD/startup-bench.exe"}
    fixtures="$PWD/fixtures";rounds=15
}
foreach ($mode in @('startup','mutated')) {
    $config.mutate_crt = $mode -eq 'mutated'
    if ($mode -eq 'mutated') { $config.cases = @('encode-small') }
    $config | ConvertTo-Json -Depth 4 | Set-Content "reports/$mode-config.json"
    python scripts/benchmark.py --config "reports/$mode-config.json" --output "reports/$mode-performance.json"
    $report = Get-Content "reports/$mode-performance.json" -Raw | ConvertFrom-Json
    if ($null -eq $report.passed) { throw 'Incomplete diagnostic performance run' }
}
ConvertTo-Json -InputObject @($failures) | Set-Content reports/correctness-failures.json
if ($failures.Count) { throw ($failures -join '; ') }
# Diagnostic run: per-variant performance gates are retained in the reports.
# Workflow success certifies complete measurements and correctness only.
