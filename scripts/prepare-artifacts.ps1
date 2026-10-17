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
    source_comparison=$selection.source_comparison
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
foreach ($label in @('nojit', 'previous', 'accumulated', 'gl-nojit', 'gl-pr', 'gl-accumulated')) {
    $build = $selection.builds.$label
    if (-not $build) { continue }
    $override = $build.arch_overrides.($env:PHP_ARCH)
    if ($override) {
        foreach ($property in $override.PSObject.Properties) {
            $build | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
        }
    }
    $artifact = if ($build.artifact) { $build.artifact.Replace('{arch}', $env:PHP_ARCH).Replace('{ts}', $env:PHP_TS) } else { 'artifacts' }
    if ($build.require_gl) {
        $jobs = & gh api "repos/shivammathur/php-windows-builder/actions/runs/$($build.run)/jobs?per_page=100" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "$label job verification failed" }
        $job = @($jobs.jobs | Where-Object name -eq "php ($env:PHP_ARCH, $env:PHP_TS)")
        if ($job.Count -ne 1 -or $job[0].conclusion -ne 'success') { throw "$label lane did not pass build and PGO validation" }
    }
    if ($artifact -eq 'auto') {
        $available = & gh api "repos/shivammathur/php-windows-builder/actions/runs/$($build.run)/artifacts?per_page=100" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "$label artifact lookup failed" }
        $artifact = if ('artifacts' -in $available.artifacts.name) { 'artifacts' } else { "artifacts-source-$lane" }
    }
    & gh run download $build.run --repo shivammathur/php-windows-builder --name $artifact --dir "downloads/$label"
    if ($LASTEXITCODE -ne 0) { throw "$label artifact download failed" }
    & gh run download $build.run --repo shivammathur/php-windows-builder --name "pgo-evidence-$lane" --dir "evidence/$label"
    if ($LASTEXITCODE -ne 0) { throw "$label evidence download failed" }
    $evidence = Get-Content "evidence/$label/provenance.json" -Raw | ConvertFrom-Json
    if ($evidence.source_sha -ne $build.sha -or $evidence.sdk_sha -ne $build.sdk -or $evidence.variant -ne $build.variant) {
        throw "$label source/SDK provenance mismatch"
    }
    if ($build.require_gl) {
        $checks = @(Get-Content "evidence/$label/static-pgo-compiler-checks.json" -Raw | ConvertFrom-Json)
        if ($checks.Count -ne 4 -or @($checks | Where-Object { -not $_.has_both_phases -or -not $_.all_have_gl_o2 }).Count) {
            throw "$label missing static-extension PGO compiler flags"
        }
        if (-not (Test-Path "evidence/$label/jit-profile-functions.txt")) { throw "$label missing JIT profile evidence" }
    }
    if ($label -eq 'gl-nojit') {
        $training = Get-Content "evidence/$label/jit-training-validation.json" -Raw | ConvertFrom-Json
        if ($training.jit_training_expected -ne $false -or $training.training_passes -ne 2 -or
            -not $training.trace_counters.Count -or @($training.trace_counters | Where-Object entry_count -gt 0).Count) {
            throw 'SDK master control did not establish two-pass training without JIT'
        }
    }
    if ($build.training_stack_reserve) {
        $instrumented = Get-Content "evidence/$label/profiles/initialized/Makefile" -Raw
        $optimized = Get-Content "evidence/$label/Makefile.pgo" -Raw
        foreach ($sapi in @('CGI', 'CLI', 'CLI_WIN32')) {
            if ($instrumented -notmatch "(?m)^LDFLAGS_$sapi=.*?/stack:$($build.training_stack_reserve)\b") {
                throw "$label missing instrumented $sapi stack reservation"
            }
            if ($optimized -notmatch "(?m)^LDFLAGS_$sapi=.*?/stack:67108864\b") {
                throw "$label optimized $sapi stack reservation changed"
            }
        }
        if ($instrumented -match 'MEMMAX|MEMMIN' -or $instrumented -notmatch '/GENPROFILE|/LTCG:PGINSTRUMENT') {
            throw "$label profiling buffers changed or instrumentation missing"
        }
        if ($optimized -match '/GENPROFILE|/LTCG:PGINSTRUMENT|MEMMAX|MEMMIN') { throw "$label instrumented flags leaked into optimized build" }
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
        training_stack_reserve=$build.training_stack_reserve
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
