$ErrorActionPreference = 'Stop'
$manifest = Get-Content (Join-Path $env:GITHUB_WORKSPACE 'manifest.json') -Raw | ConvertFrom-Json
$lane = $manifest.lanes.($env:TEST_PHP_VERSION)
$artifactDirectory = Join-Path $env:GITHUB_WORKSPACE 'external/source-artifacts'
$reportDirectory = Join-Path $env:RUNNER_TEMP "php-artifact-qa-$env:TEST_PHP_VERSION-$env:TEST_ARCH"
New-Item $reportDirectory -ItemType Directory -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
Import-Module (Join-Path $env:GITHUB_WORKSPACE 'php-builder/php/BuildPhp') -Force

foreach ($ts in @('ts', 'nts')) {
    $entry = [ordered]@{ php = $env:TEST_PHP_VERSION; arch = $env:TEST_ARCH; ts = $ts; status = 'failed' }
    try {
        $zips = @(Get-ChildItem $artifactDirectory -File | Where-Object {
            $_.Name -match "^php-([0-9].*?)(-nts)?-Win32-$($lane.vs)-$env:TEST_ARCH\.zip$" -and
            (($_.Name -match '-nts-') -eq ($ts -eq 'nts'))
        })
        if ($zips.Count -ne 1) { throw "Expected one runtime archive for $ts; found $($zips.Count)" }
        $zip = $zips[0]
        $expected = $lane.php_archives.($zip.Name)
        if (-not $expected) { throw "Archive not in pinned manifest: $($zip.Name)" }
        $actualHash = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expected.sha256) { throw "SHA256 mismatch for $($zip.Name)" }
        $entry.archive = $zip.Name
        $entry.sha256 = $actualHash
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
        try {
            $exeEntry = $archive.GetEntry('php.exe')
            if (-not $exeEntry) { throw 'php.exe is missing from the runtime archive' }
            $stream = $exeEntry.Open()
            $buffer = [System.IO.MemoryStream]::new()
            try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $stream.Dispose(); $buffer.Dispose() }
            $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
            $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
            $expectedMachine = if ($env:TEST_ARCH -eq 'x64') { 0x8664 } else { 0x14c }
            if ($machine -ne $expectedMachine) { throw "Incorrect PE architecture: $machine" }
            if ($ts -eq 'ts' -and -not $archive.GetEntry('php8apache2_4.dll')) {
                throw 'Thread-safe artifact does not include the Apache SAPI'
            }
        } finally { $archive.Dispose() }
        Invoke-PhpSmokeTests -ArtifactsDirectory $artifactDirectory -Arch $env:TEST_ARCH -Ts $ts *>&1 |
            Tee-Object -FilePath (Join-Path $reportDirectory "$ts-smoke.log") | Out-Host
        $entry.status = 'passed'
    } catch {
        $entry.error = $_.Exception.Message
        $failures.Add("${ts}: $($_.Exception.Message)")
    } finally {
        $results.Add([pscustomobject]$entry)
    }
}
$results | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $reportDirectory 'results.json')
if ($failures.Count) { throw ($failures -join "`n") }
