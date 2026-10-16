param(
    [Parameter(Mandatory = $true)] [string] $BaselinePhp,
    [Parameter(Mandatory = $true)] [string] $CandidatePhp,
    [int] $Samples = 10
)

$ErrorActionPreference = 'Stop'
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$env:TEST_PHP_ARGS = '-n'
$env:TEST_PHP_JUNIT = ''
$runner = (Resolve-Path 'source/run-tests.php').Path
$test = (Resolve-Path 'source/sapi/cgi/tests').Path
$results = [System.Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Force results/cgi | Out-Null
New-Item -ItemType Directory -Force results/dumps | Out-Null
$dumpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\php-cgi.exe'
New-Item -Path $dumpKey -Force | Out-Null
New-ItemProperty -Path $dumpKey -Name DumpFolder -Value (Resolve-Path 'results/dumps').Path -PropertyType ExpandString -Force | Out-Null
New-ItemProperty -Path $dumpKey -Name DumpType -Value 2 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $dumpKey -Name DumpCount -Value 10 -PropertyType DWord -Force | Out-Null
$startedAt = Get-Date

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
        $passed = $exitCode -eq 0 -and $log -match 'PASS path info request without exported PATH_INFO' -and $log -match 'Tests failed\s*:\s*0\s'
        $results.Add([pscustomobject]@{ label=$label; sample=$sample; exit_code=$exitCode; passed=$passed })
        if (-not $passed) {
            Write-Host $log
            Get-ChildItem 'source/sapi/cgi/tests/*' -File |
                Where-Object { $_.Extension -in '.diff', '.out', '.log', '.exp', '.php', '.sh' } |
                Copy-Item -Destination { "results/cgi/$label-$sample-$($_.Name)" }
        }
    }
}

$results | ConvertTo-Json -Depth 4 | Set-Content results/cgi-results.json
Get-WinEvent -FilterHashtable @{ LogName='Application'; StartTime=$startedAt; Id=1000,1001 } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message | ConvertTo-Json -Depth 4 | Set-Content results/application-errors.json
$failed = @($results | Where-Object { -not $_.passed })
Write-Host "CGI suite: $($results.Count - $failed.Count)/$($results.Count) repetitions passed"
if ($failed.Count) { throw "$($failed.Count) CGI suite repetitions failed; see diagnostic artifacts" }
