param([Parameter(Mandatory)] [string] $Vs, [Parameter(Mandatory)] [string] $Arch)
$ErrorActionPreference = 'Stop'
$row = @(Get-Content native-plan.json -Raw | ConvertFrom-Json | Where-Object { $_.vs -eq $Vs -and $_.arch -eq $Arch })
if ($row.Count -ne 1) { throw 'Expected one native artifact plan' }
$row = $row[0]
New-Item -ItemType Directory reports -Force | Out-Null
Invoke-WebRequest $row.baseline.url -OutFile baseline.zip
if ((Get-FileHash baseline.zip).Hash.ToLowerInvariant() -ne $row.baseline.sha256) { throw 'Baseline archive hash mismatch' }
if ((Get-FileHash uncached/lib/libjpeg_a.lib).Hash.ToLowerInvariant() -ne $row.candidate.library_sha256) { throw 'Uncached archive hash mismatch' }
Expand-Archive baseline.zip -DestinationPath baseline -Force
foreach ($variant in @('baseline','candidate','uncached')) {
    & cl /nologo /O2 /MD /W3 "/I$variant/include" tests/jpeg-bench.c /link "/LIBPATH:$variant/lib" libjpeg_a.lib "/OUT:$variant-bench.exe"
    if ($LASTEXITCODE -ne 0) { throw "Could not link $variant benchmark" }
}
& cl /nologo /O2 /MD /W3 /Ijpeg-build /Ijpeg-src/src /Ijpeg-src/simd tests/jpeg-cpu-cache.c /link /LIBPATH:candidate/lib libjpeg_a.lib /OUT:jpeg-cpu-cache.exe
if ($LASTEXITCODE -ne 0) { throw 'Could not link CPU cache test' }
$output = & ./jpeg-cpu-cache.exe
if ($LASTEXITCODE -ne 0) { throw 'CPU cache concurrency or environment test failed' }
$output | Set-Content reports/cpu-cache.json -Encoding utf8
$output | Write-Host
@{ kind='native';baseline="$PWD/baseline-bench.exe";candidate="$PWD/candidate-bench.exe";uncached="$PWD/uncached-bench.exe";fixtures="$PWD/fixtures";rounds=9 } | ConvertTo-Json | Set-Content reports/benchmark-config.json -Encoding utf8
@{
    vs=$Vs;arch=$Arch;experimental_patch_sha256=(Get-FileHash patches/libjpeg-cpu-cache.patch).Hash.ToLowerInvariant()
    original_run_id=$row.candidate.run_id;original_artifact_id=$row.candidate.artifact_id
    candidate_library_sha256=(Get-FileHash candidate/lib/libjpeg_a.lib).Hash.ToLowerInvariant()
    uncached_library_sha256=$row.candidate.library_sha256;baseline_zip_sha256=$row.baseline.sha256
    compiler=(Get-Item (Get-Command cl).Source).VersionInfo.FileVersion
    cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
} | ConvertTo-Json -Depth 6 | Set-Content reports/provenance.json -Encoding utf8
python scripts/benchmark.py --config reports/benchmark-config.json --output reports/native-performance.json
if ($LASTEXITCODE -ne 0) { throw 'Cached JPEG performance comparison failed' }
