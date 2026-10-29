param([string] $Vs, [string] $Arch)
$ErrorActionPreference = 'Stop'
$plan = Get-Content release-plan.json -Raw | ConvertFrom-Json
$rows = @($plan.native | Where-Object { $_.vs -eq $Vs -and $_.arch -eq $Arch })
if ($rows.Count -ne 1) { throw 'Expected one pinned native build' }
$row = $rows[0]
New-Item reports -ItemType Directory -Force | Out-Null
$hash = (Get-FileHash candidate/lib/libjpeg_a.lib -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $row.library_sha256) { throw 'Library hash mismatch' }
$config = Get-Content candidate/include/jconfig.h -Raw
$hasSimd = $config -match '(?m)^#define\s+WITH_SIMD\s+1\b'
if ($hasSimd -ne $row.simd_enabled) { throw 'SIMD configuration differs from the release plan' }
if ([bool](Test-Path candidate/lib/simd.pdb) -ne $hasSimd) { throw 'Unexpected SIMD PDB presence/absence' }
$bom = Get-Content candidate/share/sbom/libjpeg-turbo.cdx.json -Raw | ConvertFrom-Json
if ($bom.metadata.component.version -ne '3.2.1') { throw 'Wrong JPEG version' }
$source = @($bom.metadata.component.properties | Where-Object name -eq 'php:source-commit')
if ($source.Count -ne 1 -or $source[0].value -ne '5e31759d415fef210f96b75bab79fe22aa77680a') { throw 'Unexpected source patch' }
$symbols = (& dumpbin /symbols candidate/lib/libjpeg_a.lib) -join "`n"
if ($LASTEXITCODE) { throw 'Could not inspect library symbols' }
if (($symbols -match 'jpeg_simd_cpu_support') -ne $hasSimd) { throw 'SIMD implementation differs from installed headers' }
& cl /nologo /O2 /MD /W3 /DEXPECT_JPEG_ABI=80 /Icandidate/include tests/jpeg-consumer.c /link /LIBPATH:candidate/lib libjpeg_a.lib /OUT:consumer.exe
if ($LASTEXITCODE) { throw 'Installed library did not link' }
$env:JPEGMEM = '1234'
try {
    foreach ($forced in @($false, $true)) {
        if ($forced) { $env:JSIMD_FORCENONE = '1' } else { Remove-Item Env:JSIMD_FORCENONE -ErrorAction SilentlyContinue }
        & ./consumer.exe
        if ($LASTEXITCODE) { throw 'Native round-trip or memory control failed' }
    }
} finally {
    Remove-Item Env:JPEGMEM,Env:JSIMD_FORCENONE -ErrorAction SilentlyContinue
}
@{passed=$true;run_id=$row.run_id;artifact_id=$row.artifact_id;vs=$Vs;arch=$Arch;library_sha256=$hash;simd_enabled=$hasSimd;source=$source[0].value} |
    ConvertTo-Json | Set-Content reports/native.json
