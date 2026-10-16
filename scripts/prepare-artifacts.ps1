$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force results | Out-Null
$pair = @(Get-Content builds.json -Raw | ConvertFrom-Json | Where-Object { $_.branch -eq $env:PHP_BRANCH })
if ($pair.Count -ne 1) { throw 'Missing build pair' }
$pair = $pair[0]
$tsPart = if ($env:PHP_TS -eq 'nts') { '-nts' } else { '' }
$pattern = '^php-([0-9].*?)' + $tsPart + '-Win32-v[sc]\d+-' + $env:PHP_ARCH + '\.zip$'
if ($env:PHP_TS -eq 'ts') { $pattern = '^php-([0-9].*?)(?<!-nts)-Win32-v[sc]\d+-' + $env:PHP_ARCH + '\.zip$' }
$provenance = [ordered]@{ branch=$env:PHP_BRANCH; arch=$env:PHP_ARCH; ts=$env:PHP_TS; source_sha=$pair.sha }
$archiveName = $null
$runtimeVersions = @()
$dependencySets = @()
foreach ($label in @('baseline', 'candidate')) {
    $evidence = Get-Content "evidence/$label/provenance.json" -Raw | ConvertFrom-Json
    $expectedSdk = if ($label -eq 'baseline') { '87567dececcf806c83e67fceb89a3bd206e7f1b1' } else { '61aea83167d5257357915b9603d6386d56f0e37d' }
    if ($evidence.source_sha -ne $pair.sha -or $evidence.sdk_sha -ne $expectedSdk -or $evidence.variant -ne $label) {
        throw "$label source/SDK provenance mismatch"
    }
    $matches = @(Get-ChildItem "downloads/$label" -File | Where-Object { $_.Name -match $pattern })
    if ($matches.Count -ne 1) { throw "Expected one $label runtime archive, found $($matches.Count)" }
    $archive = $matches[0]
    if ($archiveName -and $archive.Name -ne $archiveName) { throw 'Archive name mismatch' }
    $archiveName = $archive.Name
    Expand-Archive -LiteralPath $archive.FullName -DestinationPath "runtime/$label"
    $php = (Resolve-Path "runtime/$label/php.exe").Path
    $runtimeInfo = & $php -n -r 'echo json_encode(["version"=>PHP_VERSION,"zts"=>PHP_ZTS,"bits"=>PHP_INT_SIZE*8,"jit"=>extension_loaded("Zend OPcache")]);'
    if ($LASTEXITCODE -ne 0) { throw "$label PHP failed to start" }
    $info = $runtimeInfo | ConvertFrom-Json
    $expectedBits = if ($env:PHP_ARCH -eq 'x64') { 64 } else { 32 }
    if ($info.bits -ne $expectedBits -or [bool]$info.zts -ne ($env:PHP_TS -eq 'ts') -or -not $info.jit) {
        throw "$label architecture/thread-safety/OPcache mismatch: $runtimeInfo"
    }
    $runtimeVersions += $info.version
    $sboms = @(Get-ChildItem "runtime/$label" -Recurse -File -Filter 'php.cdx.json')
    if ($sboms.Count -ne 1) { throw "$label missing CycloneDX SBOM" }
    $bom = Get-Content $sboms[0].FullName -Raw | ConvertFrom-Json
    $dependencySets += ,@($bom.components | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object -Unique)
    $provenance[$label] = [ordered]@{
        run=$pair.$label
        sdk_sha=$expectedSdk
        archive=$archive.Name
        sha256=(Get-FileHash $archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        runtime=$info
    }
    "${label}_php=$php" >> $env:GITHUB_OUTPUT
}
if ($runtimeVersions[0] -ne $runtimeVersions[1]) { throw 'Runtime version mismatch' }
if (Compare-Object $dependencySets[0] $dependencySets[1]) { throw 'Baseline/candidate dependency versions differ' }
$provenance.dependencies = $dependencySets[0]
$provenance.processor = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$provenance.image = $env:ImageVersion
$provenance | ConvertTo-Json -Depth 8 | Set-Content results/provenance.json
