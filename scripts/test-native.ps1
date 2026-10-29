param(
    [Parameter(Mandatory)] [string] $Vs,
    [Parameter(Mandatory)] [string] $Arch,
    [string] $PlanFile = 'native-plan.json'
)
$ErrorActionPreference = 'Stop'
$plan = Get-Content $PlanFile -Raw | ConvertFrom-Json
$row = @($plan | Where-Object { $_.vs -eq $Vs -and $_.arch -eq $Arch })
if ($row.Count -ne 1) { throw 'Expected one native artifact plan' }
$row = $row[0]
New-Item -ItemType Directory reports -Force | Out-Null
Invoke-WebRequest $row.baseline.url -OutFile baseline.zip
$baselineHash = (Get-FileHash baseline.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($baselineHash -ne $row.baseline.sha256) { throw 'Published baseline changed after capture' }
Expand-Archive baseline.zip -DestinationPath baseline -Force
foreach ($name in @('lib/libjpeg_a.lib', 'lib/libjpeg_a.pdb', 'lib/simd.pdb', 'include/jconfig.h')) {
    if (!(Test-Path "candidate/$name")) { throw "Missing candidate artifact file: $name" }
}
$hash = (Get-FileHash candidate/lib/libjpeg_a.lib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $row.candidate.library_sha256) { throw 'Candidate library hash mismatch' }
$bom = Get-Content candidate/share/sbom/libjpeg-turbo.cdx.json -Raw | ConvertFrom-Json
if ($bom.metadata.component.version -ne '3.2.1') { throw 'Candidate SBOM version mismatch' }
foreach ($variant in @('baseline','candidate')) {
    & cl /nologo /O2 /MD /W3 "/I$variant/include" tests/jpeg-bench.c /link "/LIBPATH:$variant/lib" libjpeg_a.lib "/OUT:$variant-bench.exe"
    if ($LASTEXITCODE -ne 0) { throw "Could not link benchmark with $variant" }
}
& cl /nologo /O2 /MD /W3 /DEXPECT_JPEG_ABI=80 /Icandidate/include tests/jpeg-consumer.c /link /LIBPATH:candidate/lib libjpeg_a.lib /OUT:jpeg-consumer.exe
if ($LASTEXITCODE -ne 0) { throw 'Installed candidate consumer did not link' }
& ./jpeg-consumer.exe
if ($LASTEXITCODE -ne 0) { throw 'Installed candidate round-trip failed' }
$env:JSIMD_FORCENONE = '1'
& ./jpeg-consumer.exe
if ($LASTEXITCODE -ne 0) { throw 'Scalar candidate round-trip failed' }
Remove-Item Env:JSIMD_FORCENONE
@{
    kind = 'native'
    baseline = "$PWD/baseline-bench.exe"
    candidate = "$PWD/candidate-bench.exe"
    fixtures = "$PWD/fixtures"
    rounds = 9
} | ConvertTo-Json | Set-Content reports/benchmark-config.json -Encoding utf8
@{
    vs = $Vs; arch = $Arch
    candidate_run_id = $row.candidate.run_id
    candidate_artifact_id = $row.candidate.artifact_id
    candidate_library_sha256 = $hash
    baseline_zip_sha256 = $baselineHash
    baseline_library_sha256 = (Get-FileHash baseline/lib/libjpeg_a.lib -Algorithm SHA256).Hash.ToLowerInvariant()
    compiler = (Get-Item (Get-Command cl).Source).VersionInfo.FileVersion
    cpu = @(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
} | ConvertTo-Json -Depth 6 | Set-Content reports/provenance.json -Encoding utf8
python scripts/benchmark.py --config reports/benchmark-config.json --output reports/native-performance.json
if ($LASTEXITCODE -ne 0) { throw 'Native JPEG performance comparison failed' }
