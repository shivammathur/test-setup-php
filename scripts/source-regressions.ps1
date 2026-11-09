param([Parameter(Mandatory)] [string] $Branch)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (Get-Location).Path
$manifest = Get-Content manifest.json -Raw | ConvertFrom-Json -AsHashtable
$entry = $manifest.branches[$Branch]
$report = New-Item reports -ItemType Directory -Force
$cases = [Collections.Generic.List[object]]::new()
$testsRoot = (Resolve-Path source).Path
$selected = @('Zend/tests/record_errors_001.phpt', 'ext/zend_test/tests/system_id_reinitialization.phpt', 'ext/standard/tests/ini_info/php_ini_loaded_file.phpt', 'sapi/cgi/tests/006.phpt', 'sapi/cgi/tests/011.phpt')
$available = @($selected | Where-Object { Test-Path (Join-Path $testsRoot $_) })
foreach ($file in $entry.php.GetEnumerator()) {
    $zip = Join-Path "$root/artifacts" $file.Key
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.Value.sha256) { throw 'PHP archive hash mismatch' }
    $variant = "$($file.Value.arch)-$($file.Value.ts)"
    $phpRoot = Join-Path $env:RUNNER_TEMP "focused-$variant"
    Expand-Archive $zip $phpRoot -Force
    $php = Join-Path $phpRoot 'php.exe'
    $env:PATH = "$phpRoot;$env:PATH"
    $env:TEST_PHP_EXECUTABLE = $php
    $env:TEST_PHPDBG_EXECUTABLE = Join-Path $phpRoot 'phpdbg.exe'
    $env:TEST_PHP_CGI_EXECUTABLE = Join-Path $phpRoot 'php-cgi.exe'
    $env:NO_INTERACTION = 1
    $env:REPORT_EXIT_STATUS = 1
    Push-Location $testsRoot
    try {
        foreach ($cache in 'nocache', 'opcache') {
            $settings = @('-d', "extension_dir=$phpRoot/ext", '-d', 'extension=zend_test')
            if ($cache -eq 'opcache') {
                if (Test-Path "$phpRoot/ext/php_opcache.dll") { $settings += @('-d', 'zend_extension=opcache') }
                $settings += @('-d', 'opcache.enable_cli=1', '-d', 'opcache.jit_buffer_size=64M', '-d', 'opcache.jit=tracing', '-d', 'opcache.record_warnings=1')
            } else { $settings += @('-d', 'opcache.enable_cli=0') }
            $label = "$variant-$cache"
            $env:TEST_PHP_JUNIT = Join-Path $report.FullName "$label.xml"
            # Pass INI settings individually: a forced -c contaminates php_ini_loaded_file's -n subprocess.
            & $php -n run-tests.php -p $php -n @settings --offline --show-diff -q @available *> (Join-Path $report.FullName "$label.log")
            $code = $LASTEXITCODE
            $cases.Add(@{ label=$label; exitCode=$code; tests=$available; sha256=$file.Value.sha256 })
            # Repeat the two CGI tests serially to distinguish intermittent subprocess failures.
            for ($attempt=1; $attempt -le 5; $attempt++) {
                $env:TEST_PHP_JUNIT = Join-Path $report.FullName "$label-cgi-$attempt.xml"
                & $php -n run-tests.php -p $php -n @settings --offline --show-diff -q sapi/cgi/tests/006.phpt sapi/cgi/tests/011.phpt *> (Join-Path $report.FullName "$label-cgi-$attempt.log")
                $cases.Add(@{ label="$label-cgi-$attempt"; exitCode=$LASTEXITCODE; tests=@('sapi/cgi/tests/006.phpt','sapi/cgi/tests/011.phpt') })
            }
        }
    } finally { Pop-Location }
}
$cases | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $report.FullName 'summary.json')
if (@($cases | Where-Object { $_.exitCode -ne 0 }).Count) { throw 'Focused source tests failed; inspect JUnit and logs' }
