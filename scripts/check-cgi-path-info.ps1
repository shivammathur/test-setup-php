param(
    [Parameter(Mandatory = $true)] [string] $BaselinePhp,
    [Parameter(Mandatory = $true)] [string] $CandidatePhp,
    [int] $Samples = 50
)

$ErrorActionPreference = 'Stop'
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$env:TEST_PHP_ARGS = '-n'
$env:TEST_PHP_JUNIT = ''
$runner = (Resolve-Path 'source/run-tests.php').Path
$test = (Resolve-Path 'source/sapi/cgi/tests/009.phpt').Path
$results = [System.Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Force results/cgi | Out-Null

for ($sample = 1; $sample -le $Samples; $sample++) {
    $labels = if ($sample % 2) { @('baseline', 'candidate') } else { @('candidate', 'baseline') }
    foreach ($label in $labels) {
        $php = if ($label -eq 'baseline') { $BaselinePhp } else { $CandidatePhp }
        $env:TEST_PHP_EXECUTABLE = $php
        $env:TEST_PHP_CGI_EXECUTABLE = Join-Path (Split-Path $php) 'php-cgi.exe'
        $output = & $php -n $runner -p $php -n -q --show-diff $test 2>&1
        $exitCode = $LASTEXITCODE
        $log = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        $log | Set-Content "results/cgi/$label-$sample.log"
        $passed = $exitCode -eq 0 -and $log -match 'PASS path info request without exported PATH_INFO'
        $results.Add([pscustomobject]@{ label=$label; sample=$sample; exit_code=$exitCode; passed=$passed })
        if (-not $passed) {
            Write-Host $log
            Get-ChildItem 'source/sapi/cgi/tests/009.*' -File |
                Where-Object { $_.Extension -in '.diff', '.out', '.log', '.exp', '.php', '.sh' } |
                Copy-Item -Destination { "results/cgi/$label-$sample-$($_.Name)" }
        }
    }
}

$results | ConvertTo-Json -Depth 4 | Set-Content results/cgi-results.json
$failed = @($results | Where-Object { -not $_.passed })
Write-Host "CGI path-info: $($results.Count - $failed.Count)/$($results.Count) repetitions passed"
if ($failed.Count) { throw "$($failed.Count) CGI path-info repetitions failed; see diagnostic artifacts" }
