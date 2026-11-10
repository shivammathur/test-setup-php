$ErrorActionPreference='Stop'
$manifest=Get-Content comparison-manifest.json -Raw | ConvertFrom-Json -AsHashtable
$provenance=Get-Content artifacts/comparison.json -Raw | ConvertFrom-Json -AsHashtable
if ($provenance.compiler -ne $env:COMPILER) { throw 'Unexpected compiler artifact provenance' }
$hashes=Get-Content artifacts/hashes.json -Raw | ConvertFrom-Json
foreach ($hash in $hashes) {
    $file=Join-Path artifacts ([IO.Path]::GetFileName($hash.Path))
    if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $hash.Hash) { throw "Build artifact hash mismatch: $file" }
}
$files=@{}
foreach ($zip in Get-ChildItem artifacts -Filter 'php-*.zip' | Where-Object { $_.Name -match '^php-(?!debug-pack-|devel-pack-|test-pack-).+?-nts-Win32-vs\d+-x86\.zip$' }) {
    $files[$zip.Name]=@{sha256=(Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant();arch='x86';ts='nts';vs=$env:COMPILER}
}
if ($files.Count -ne 1) { throw 'Expected one x86 NTS runtime' }
$manifest.branches=@{comparison=@{run=[long]$env:BUILD_RUN;sourceSha=$provenance.sourceSha;apacheRun=[long]$provenance.apacheRun;php=$files;vs=$env:COMPILER;runner=$env:RUNNER_OS}}
$manifest.testBranches=@('comparison')
$manifest | ConvertTo-Json -Depth 12 | Set-Content manifest.json
New-Item reports -ItemType Directory -Force | Out-Null
Copy-Item artifacts/comparison.json reports/provenance.json
Copy-Item artifacts/hashes.json reports/build-hashes.json
