param(
    [Parameter(Mandatory)] [string] $PhpTarget,
    [Parameter(Mandatory)] [string] $PlanFile,
    [string] $ArtifactsDirectory = 'artifacts',
    [string] $ReportsDirectory = 'reports'
)
$ErrorActionPreference = 'Stop'
$plan = Get-Content $PlanFile -Raw | ConvertFrom-Json
$entry = @($plan.php | Where-Object target -eq $PhpTarget)
if ($entry.Count -ne 1) { throw "Expected one plan for $PhpTarget" }
$entry = $entry[0]
New-Item -ItemType Directory -Path $ReportsDirectory -Force | Out-Null
$zips = @(Get-ChildItem $ArtifactsDirectory -Recurse -File | Where-Object Name -Match '^php-\d+\.\d+\.\d+.*?(?:-nts)?-Win32-vs\d+-(x64|x86)\.zip$')
if ($zips.Count -ne 4) { throw "Expected four runtime archives, found $($zips.Count)" }
$summary = @()
foreach ($zip in $zips) {
    $expected = @($entry.runtime_archives | Where-Object name -eq $zip.Name)
    if ($expected.Count -ne 1) { throw "Unexpected archive $($zip.Name)" }
    $hash = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $expected[0].sha256) { throw "Archive hash mismatch: $($zip.Name)" }
    $out = Join-Path $PWD "runtime/$($zip.BaseName)"
    Expand-Archive $zip.FullName -DestinationPath $out -Force
    $php = Join-Path $out 'php.exe'
    $gd = Join-Path $out 'ext/php_gd.dll'
    if (!(Test-Path $php) -or !(Test-Path $gd)) { throw 'Missing PHP runtime or GD extension' }
    $boms = @(Get-ChildItem $out -Recurse -File | Where-Object { $_.Name -match '\.(cdx|bom)\.json$|^sbom.*\.json$' })
    $jpeg = @()
    foreach ($bom in $boms) {
        $document = Get-Content $bom.FullName -Raw | ConvertFrom-Json
        $jpeg += @($document.components | Where-Object { $_.name -in 'libjpeg-turbo', 'libjpeg' })
    }
    if (!$jpeg) { throw "No JPEG component in runtime SBOM: $($zip.Name)" }
    if (@($jpeg | Where-Object version -ne '3.2.1').Count) { throw 'Runtime SBOM contains an unexpected JPEG version' }
    $savedPath = $env:PATH
    try {
        $env:PATH = "$out;$savedPath"
        foreach ($scalar in @($false, $true)) {
            if ($scalar) { $env:JSIMD_FORCENONE = '1' } else { Remove-Item Env:JSIMD_FORCENONE -ErrorAction SilentlyContinue }
            $suffix = if ($scalar) { 'scalar' } else { 'default' }
            $output = & $php -n -d "extension_dir=$out/ext" -d extension=gd tests/jpeg-roundtrip.php 2>&1
            $exitCode = $LASTEXITCODE
            $report = Join-Path $ReportsDirectory "$($zip.BaseName)-$suffix.json"
            $output | Set-Content $report -Encoding utf8
            if ($exitCode -ne 0) { $output | Write-Host; throw "JPEG QA failed: $($zip.Name) $suffix" }
            $result = ($output -join "`n") | ConvertFrom-Json
            if (!$result.passed) { throw "JPEG QA reported failure: $($zip.Name) $suffix" }
            $arch = if ($zip.Name -match '-x64\.zip$') { 64 } else { 32 }
            if ($result.bits -ne $arch) { throw 'Runtime architecture mismatch' }
            $zts = if ($zip.Name -match '-nts-') { 0 } else { 1 }
            if ($result.zts -ne $zts) { throw 'Runtime thread-safety mismatch' }
            if ($result.forced_scalar_environment -ne $scalar) { throw 'Environment test mode mismatch' }
            Write-Host "$($zip.Name) ${suffix}: $($result.cases.Count) cases passed"
            $summary += @{ archive = $zip.Name; sha256 = $hash; gd_sha256 = (Get-FileHash $gd -Algorithm SHA256).Hash.ToLowerInvariant(); mode = $suffix; cases = $result.cases.Count; php = $result.php; run_id = $entry.run_id }
        }
    } finally {
        $env:PATH = $savedPath
        Remove-Item Env:JSIMD_FORCENONE -ErrorAction SilentlyContinue
    }
}
$summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $ReportsDirectory 'summary.json') -Encoding utf8
