$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$reports = (New-Item -ItemType Directory -Path "$root/reports" -Force).FullName
$temp = (New-Item -ItemType Directory -Path "$root/tmp" -Force).FullName
$suffix = if ($env:PHPTS -eq 'nts') { '-nts' } else { '' }
$variants = [ordered]@{ historical = ''; baseline = $env:BASELINE_RUN; patched = $env:PATCHED_RUN }
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'

function Test-Variant([string] $variant) {
    $download = (New-Item -ItemType Directory -Path "$env:RUNNER_TEMP/nul-$variant" -Force).FullName
    if ($variant -eq 'historical') {
        $zip = Join-Path $download "php-8.2.33$suffix-Win32-vs16-$($env:ARCH).zip"
        Invoke-WebRequest "https://downloads.php.net/~windows/releases/archives/$([IO.Path]::GetFileName($zip))" -OutFile $zip
    } else {
        gh run download $variants[$variant] -R shivammathur/php-windows-builder -n artifacts -D $download
        if ($LASTEXITCODE -ne 0) { throw "Artifact download failed: $variant" }
        $zips = @(Get-ChildItem $download -Filter '*.zip' | Where-Object {
            $_.Name -match "^php-8\.2\..+-Win32-vs16-$($env:ARCH)\.zip$" -and
            $_.Name.Contains('-nts-') -eq ($env:PHPTS -eq 'nts')
        })
        if ($zips.Count -ne 1) { throw "Expected one binary ZIP for $variant, found $($zips.Count)" }
        $zip = $zips[0].FullName
    }
    Get-FileHash $zip | ConvertTo-Json | Set-Content "$reports/$variant-archive.json"
    $binary = Join-Path $download 'binary'
    Expand-Archive $zip $binary
    $php = Join-Path $binary 'php.exe'
    $json = & $php -n -d "sys_temp_dir=$temp" "$root/symfony.php"
    if ($LASTEXITCODE -ne 0) { throw "Symfony test failed to execute: $variant, $json" }
    $json | Tee-Object -FilePath "$reports/$variant-symfony.json"
    $report = $json | ConvertFrom-Json
    $version = if ($variant -eq 'historical') { '8.2.33' } else { '8.2.34-dev' }
    $bits = if ($env:ARCH -eq 'x64') { 64 } else { 32 }
    if ($report.php -ne $version -or $report.zts -ne ($env:PHPTS -eq 'ts') -or $report.bits -ne $bits) {
        throw "Unexpected PHP build: $variant"
    }
    foreach ($result in $report.results.PSObject.Properties) {
        if ($result.Value.success -ne ($variant -ne 'baseline')) {
            throw "Unexpected Symfony result: $variant $($result.Name)"
        }
        if ($variant -eq 'baseline' -and ($result.Value | ConvertTo-Json -Depth 4) -notmatch 'NUL|open_basedir') {
            throw 'Baseline did not fail for the reported reason'
        }
    }

    $env:TEST_PHP_EXECUTABLE = $php
    $env:TEST_PHP_JUNIT = "$reports/$variant-phpt.xml"
    Push-Location "$root/php-src"
    try {
        $test = 'tests/security/open_basedir_nul_win32.phpt'
        & $php -n run-tests.php -n -q --no-progress --show-diff $test 2>&1 | Tee-Object -FilePath "$reports/$variant-phpt.log"
        $exit = $LASTEXITCODE
        [xml]$xml = Get-Content $env:TEST_PHP_JUNIT -Raw
        $cases = @($xml.SelectNodes('//testcase'))
        $failures = @($xml.SelectNodes('//testcase/failure'))
        if ($cases.Count -ne 1 -or $xml.SelectNodes('//testcase/skipped').Count -ne 0) { throw 'Regression test did not execute' }
        if ($variant -eq 'baseline') {
            if ($exit -eq 0 -or $failures.Count -ne 1) { throw 'Baseline did not reproduce the regression' }
            $output = Get-Content 'tests/security/open_basedir_nul_win32.out' -Raw
            if ($output -notmatch 'Directory allowed:\r?\nbool\(true\)\r?\nbool\(false\)\r?\nbool\(false\)\r?\nbool\(false\)') {
                throw 'Unexpected baseline failure'
            }
            Copy-Item 'tests/security/open_basedir_nul_win32.diff' "$reports/baseline.diff"
        } elseif ($exit -ne 0 -or $failures.Count -ne 0) {
            throw "Regression test failed: $variant"
        }
    } finally {
        Pop-Location
    }
}

$failures = @()
foreach ($variant in $variants.Keys) {
    try {
        Test-Variant $variant
    } catch {
        $failures += "${variant}: $_"
        Write-Warning $failures[-1]
    }
}
if ($failures.Count) { throw ($failures -join "`n") }
