$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force results | Out-Null
$selection = @(Get-Content builds.json -Raw | ConvertFrom-Json | Where-Object { $_.branch -eq $env:PHP_BRANCH })
if ($selection.Count -ne 1) { throw 'Missing build selection' }
$selection = $selection[0]
$lane = "$env:PHP_ARCH-$env:PHP_TS"
$validTraining = $lane -notin @($selection.invalid_lanes)
$provenance = [ordered]@{
    branch=$env:PHP_BRANCH; arch=$env:PHP_ARCH; ts=$env:PHP_TS; source_sha=$selection.sha
    valid_training=$validTraining; caveat=$(if (-not $validTraining) { $selection.caveat } else { $null })
    builds=[ordered]@{}
}
if (-not $validTraining) { Write-Host "::warning::$($selection.caveat)" }
$tsPart = if ($env:PHP_TS -eq 'nts') { '-nts' } else { '' }
$pattern = '^php-([0-9].*?)' + $tsPart + '-Win32-v[sc]\d+-' + $env:PHP_ARCH + '\.zip$'
if ($env:PHP_TS -eq 'ts') { $pattern = '^php-([0-9].*?)(?<!-nts)-Win32-v[sc]\d+-' + $env:PHP_ARCH + '\.zip$' }
$paths = [ordered]@{}
$archiveName = $null
$runtimeVersion = $null
$dependencies = $null
foreach ($label in @('nojit', 'previous', 'fixed')) {
    $build = $selection.builds.$label
    if (-not $build) { continue }
    $artifact = if ($build.artifact) { $build.artifact.Replace('{arch}', $env:PHP_ARCH).Replace('{ts}', $env:PHP_TS) } else { 'artifacts' }
    & gh run download $build.run --repo shivammathur/php-windows-builder --name $artifact --dir "downloads/$label"
    if ($LASTEXITCODE -ne 0) { throw "$label artifact download failed" }
    & gh run download $build.run --repo shivammathur/php-windows-builder --name "pgo-evidence-$lane" --dir "evidence/$label"
    if ($LASTEXITCODE -ne 0) { throw "$label evidence download failed" }
    $evidence = Get-Content "evidence/$label/provenance.json" -Raw | ConvertFrom-Json
    if ($evidence.source_sha -ne $selection.sha -or $evidence.sdk_sha -ne $build.sdk -or $evidence.variant -ne $build.variant) {
        throw "$label source/SDK provenance mismatch"
    }
    $matches = @(Get-ChildItem "downloads/$label" -Recurse -File | Where-Object { $_.Name -match $pattern })
    if ($matches.Count -ne 1) { throw "Expected one $label runtime archive, found $($matches.Count)" }
    $archive = $matches[0]
    if ($archiveName -and $archive.Name -ne $archiveName) { throw 'Archive name mismatch' }
    $archiveName = $archive.Name
    Expand-Archive -LiteralPath $archive.FullName -DestinationPath "runtime/$label"
    $php = (Resolve-Path "runtime/$label/php.exe").Path
    $arguments = @('-n')
    $opcache = Join-Path (Split-Path $php) 'ext/php_opcache.dll'
    if (Test-Path $opcache) { $arguments += @('-d', "zend_extension=$opcache") }
    $arguments += @('-r', 'echo json_encode(["version"=>PHP_VERSION,"zts"=>PHP_ZTS,"bits"=>PHP_INT_SIZE*8,"opcache"=>extension_loaded("Zend OPcache")]);')
    $runtimeInfo = & $php @arguments
    if ($LASTEXITCODE -ne 0) { throw "$label PHP failed to start" }
    $info = $runtimeInfo | ConvertFrom-Json
    $expectedBits = if ($env:PHP_ARCH -eq 'x64') { 64 } else { 32 }
    if ($info.bits -ne $expectedBits -or [bool]$info.zts -ne ($env:PHP_TS -eq 'ts') -or -not $info.opcache) {
        throw "$label architecture/thread-safety/OPcache mismatch: $runtimeInfo"
    }
    if ($runtimeVersion -and $info.version -ne $runtimeVersion) { throw 'Runtime version mismatch' }
    $runtimeVersion = $info.version
    $sboms = @(Get-ChildItem "runtime/$label" -Recurse -File -Filter 'php.cdx.json')
    if ($sboms.Count -ne 1) { throw "$label missing CycloneDX SBOM" }
    $bom = Get-Content $sboms[0].FullName -Raw | ConvertFrom-Json
    $currentDependencies = @($bom.components | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object -Unique)
    if ($dependencies -and (Compare-Object $dependencies $currentDependencies)) { throw "$label dependency versions differ" }
    $dependencies = $currentDependencies
    $provenance.builds[$label] = [ordered]@{
        run=$build.run; sdk_sha=$build.sdk; archive=$archive.Name
        sha256=(Get-FileHash $archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        runtime=$info; build_provenance=$evidence
    }
    $paths[$label] = $php
}
$provenance.dependencies = $dependencies
$provenance.processor = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$provenance.image = $env:ImageVersion
$provenance | ConvertTo-Json -Depth 10 | Set-Content results/provenance.json
$paths | ConvertTo-Json | Set-Content results/runtime-paths.json
"jit=$($selection.jit.ToString().ToLowerInvariant())" >> $env:GITHUB_OUTPUT
"regression=$($paths.Contains('nojit').ToString().ToLowerInvariant())" >> $env:GITHUB_OUTPUT
