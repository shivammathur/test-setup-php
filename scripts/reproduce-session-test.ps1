$ErrorActionPreference = 'Stop'
$root = $env:GITHUB_WORKSPACE
$manifest = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
$lane = $manifest.lanes.'8.2'
$reports = Join-Path $env:RUNNER_TEMP "php-artifact-qa-8.2-$env:TEST_ARCH"
$testSource = Join-Path $root 'php-session-source'
$records = [System.Collections.Generic.List[object]]::new()
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
Push-Location $testSource
try {
    foreach ($ts in @('ts', 'nts')) {
        $zip = @(Get-ChildItem (Join-Path $root 'external/source-artifacts') -File | Where-Object {
            $_.Name -match "^php-8\.2\..*(-nts)?-Win32-vs16-$env:TEST_ARCH\.zip$" -and
            (($_.Name -match '-nts-') -eq ($ts -eq 'nts'))
        })
        if ($zip.Count -ne 1) { throw "Expected one exact PHP 8.2 $ts archive" }
        if ((Get-FileHash $zip[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $lane.php_archives.($zip[0].Name).sha256) {
            throw 'Session reproduction PHP archive checksum mismatch'
        }
        $phpRoot = Join-Path $env:RUNNER_TEMP "session-php-$env:TEST_ARCH-$ts"
        Expand-Archive $zip[0].FullName -DestinationPath $phpRoot -Force
        $phpExe = Join-Path $phpRoot 'php.exe'
        $env:TEST_PHP_EXECUTABLE = $phpExe
        $env:TEST_PHP_CGI_EXECUTABLE = Join-Path $phpRoot 'php-cgi.exe'
        foreach ($cache in @('opcache', 'nocache')) {
            for ($repeat = 1; $repeat -le 3; $repeat++) {
                $label = "session-$ts-$cache-$repeat"
                $env:TEST_PHP_JUNIT = Join-Path $reports "$label.xml"
                $parameters = @('-n', 'run-tests.php', '-p', $phpExe, '-n', '-q', '--offline', '--show-diff')
                if ($cache -eq 'opcache') {
                    $parameters += @('-d', "zend_extension=$phpRoot/ext/php_opcache.dll", '-d', 'opcache.enable_cli=1')
                }
                $parameters += 'ext/session/tests/rfc1867_sid_invalid.phpt'
                & $phpExe @parameters 2>&1 | Tee-Object -FilePath (Join-Path $reports "$label.log") | Out-Host
                $exitCode = $LASTEXITCODE
                if (-not (Test-Path $env:TEST_PHP_JUNIT)) { throw "Missing session test report: $label" }
                [xml] $junit = Get-Content $env:TEST_PHP_JUNIT -Raw
                $cases = @($junit.SelectNodes('//testcase'))
                $problems = @($junit.SelectNodes('//failure|//error|//skipped'))
                $passed = $exitCode -eq 0 -and $cases.Count -eq 1 -and $problems.Count -eq 0
                $records.Add([pscustomobject]@{ts=$ts; opcache=$cache; repeat=$repeat; passed=$passed; exit_code=$exitCode})
            }
        }
    }
} finally {
    Pop-Location
    $records | ConvertTo-Json | Set-Content (Join-Path $reports 'session-reproduction.json')
}
if ($records.Count -ne 12 -or @($records | Where-Object { -not $_.passed }).Count) { throw 'Session reproduction has failed or missing tests' }
