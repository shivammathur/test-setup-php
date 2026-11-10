param([string[]]$Variants, [string[]]$BuildRuns)
$ErrorActionPreference='Stop'
if ($Variants.Count -ne $BuildRuns.Count) { throw 'Build input count mismatch' }
$manifest=Get-Content comparison-manifest.json -Raw | ConvertFrom-Json -AsHashtable
$sources=Get-Content source-manifest.json -Raw | ConvertFrom-Json -AsHashtable
$manifest.branches=@{}
$debug=@();$provenance=@{}
New-Item reports -ItemType Directory -Force | Out-Null
foreach ($i in 0..($Variants.Count-1)) {
    $variant=$Variants[$i];$directory="builds/$variant"
    $build=Get-Content "$directory/comparison.json" -Raw | ConvertFrom-Json -AsHashtable
    if ($build.variant -ne $variant -or $build.sourceSha -ne $sources[$variant].sourceSha) { throw 'Unexpected source provenance' }
    foreach ($hash in (Get-Content "$directory/hashes.json" -Raw | ConvertFrom-Json)) {
        $file=Join-Path $directory ([IO.Path]::GetFileName($hash.Path))
        if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $hash.Hash) { throw "Artifact hash mismatch: $file" }
    }
    $files=@{}
    foreach ($zip in Get-ChildItem $directory -Filter 'php-*.zip' | Where-Object { $_.Name -match '^php-(?!debug-pack-|devel-pack-|test-pack-).+?-(?:nts-)?Win32-vs\d+-(?:x86|x64)\.zip$' }) {
        $files[$zip.Name]=@{sha256=(Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant();arch=$build.arch;ts=$build.ts;vs=$build.compiler}
    }
    if ($files.Count -ne 1) { throw 'Expected exactly one runtime in each build' }
    $entry=@{run=[long]$BuildRuns[$i];sourceSha=$build.sourceSha;sourceRepo='shivammathur/php-src';apacheRun=[long]$build.apacheRun;php=$files;vs=$build.compiler;runner=$env:RUNNER_OS}
    $manifest.branches[$variant]=$entry
    $provenance[$variant]=$build
    $runtime=@($files.Keys)[0]
    $pack=@(Get-ChildItem $directory -Filter 'php-debug-pack-*.zip')
    if ($pack.Count -ne 1) { throw 'Expected exactly one debug pack' }
    $debug+=@{branch=$variant;arch=$build.arch;flavor=$sources[$variant].flavor;runtime=$runtime;runtimeSha256=$files[$runtime].sha256;debugPack=$pack[0].Name;debugSha256=(Get-FileHash $pack[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant();sourceSha=$build.sourceSha;run=[long]$BuildRuns[$i]}
}
$manifest.testBranches=$Variants
$manifest | ConvertTo-Json -Depth 12 | Set-Content manifest.json
$debug | ConvertTo-Json -Depth 8 | Set-Content debug-manifest.json
$provenance | ConvertTo-Json -Depth 8 | Set-Content reports/provenance.json
if ($Variants.Count -eq 1 -and $env:GITHUB_OUTPUT) { "source-sha=$($provenance[$Variants[0]].sourceSha)" >> $env:GITHUB_OUTPUT }
