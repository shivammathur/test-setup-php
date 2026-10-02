param([string]$Php, [string]$Arch, [string]$Ts, [string]$Opcache)
$ErrorActionPreference = 'Stop'
$row = @((Get-Content recheck-manifest.json -Raw | ConvertFrom-Json).php | Where-Object php -EQ $Php)[0]
$runtime = @($row.runtimeZips | Where-Object { $_.arch -eq $Arch -and $_.ts -eq $Ts })[0]
New-Item reports -ItemType Directory -Force | Out-Null
$headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json' }
$api = 'https://api.github.com/repos/shivammathur/php-windows-builder'
$a = Invoke-RestMethod "$api/actions/artifacts/$($row.artifactId)" -Headers $headers
if ($a.workflow_run.id -ne $row.runId -or $a.expired -or $a.name -ne 'artifacts') { throw 'Wrong recheck artifact' }
Invoke-WebRequest "$api/actions/artifacts/$($row.artifactId)/zip" -Headers $headers -OutFile merged.zip
if ((Get-FileHash merged.zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $row.artifactSha256) { throw 'Merged artifact changed' }
Expand-Archive merged.zip . -Force
if ((Get-FileHash $runtime.name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $runtime.sha256) { throw 'Runtime artifact changed' }
$env:LIBS_BUILD_RUNS = $row.dependencies -join ','
$env:GITHUB_TOKEN = $env:GH_TOKEN
Import-Module ./builder/php/BuildPhp -Force
Invoke-PhpTests -PhpVersion $runtime.phpVersion -Arch $Arch -Ts $Ts -Opcache $Opcache -TestType php `
    -SourceRepository php/php-src -SourceRef $row.sourceCommit -TestDirectories @('sapi/cli/tests','sapi/cgi/tests')
$workspace = (Get-Location).Path
$phpExe = $env:TEST_PHP_EXECUTABLE
$phpBin = Split-Path $phpExe
$testRoot = Join-Path (Split-Path $phpBin) tests
$ini = Join-Path $phpBin php-test.ini
foreach ($p in $runtime.dllHashes.PSObject.Properties) {
    if ((Get-FileHash (Join-Path $phpBin $p.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $p.Value) {
        throw "Recheck loaded a different dependency: $($p.Name)"
    }
}
$reports = @()
function Inspect-Junit([string]$Path, [int]$Expected = 0) {
    [xml]$xml = Get-Content $Path -Raw
    $cases = @($xml.SelectNodes('//testcase'))
    $failed = @($xml.SelectNodes('//testcase/failure|//testcase/error'))
    $skipped = @($xml.SelectNodes('//testcase/skipped'))
    if ($Expected -gt 0 -and ($cases.Count -ne $Expected -or $skipped.Count -gt 0)) { throw 'Missing or skipped repeated PHPT tests' }
    return @{ file = Split-Path $Path -Leaf; cases = $cases.Count; skipped = $skipped.Count; failures = $failed.Count }
}
$main = Join-Path $workspace "test-$Arch-$Ts-$Opcache-php.xml"
$reports += Inspect-Junit $main
Copy-Item $main reports
Copy-Item "test-$Arch-$Ts-$Opcache-php.log" reports
$tests = @('sapi/cli/tests/gh18582.phpt', 'sapi/cli/tests/bug65633.phpt', 'sapi/cli/tests/gh22003.phpt', 'sapi/cgi/tests/004.phpt')
Push-Location $testRoot
try {
    for ($iteration=1; $iteration -le 20; $iteration++) {
        $env:TEST_PHP_JUNIT = Join-Path $workspace "reports/recheck-$iteration.xml"
        & $phpExe -n run-tests.php -p $phpExe -n -c $ini -q --offline --show-diff @tests 2>&1 |
            Tee-Object -FilePath (Join-Path $workspace "reports/recheck-$iteration.log") | Out-Host
        $reports += Inspect-Junit $env:TEST_PHP_JUNIT 4
    }
} finally { Pop-Location }
$result = @{ php=$Php; arch=$Arch; ts=$Ts; opcache=$Opcache; sourceRunId=$row.runId; sourceCommit=$row.sourceCommit; artifactId=$row.artifactId; artifactSha256=$row.artifactSha256; runtimeSha256=$runtime.sha256; reports=$reports }
$result | ConvertTo-Json -Depth 20 | Set-Content reports/recheck-results.json
if (@($reports | Where-Object failures -GT 0).Count -gt 0) { throw 'PHPT failures reproduced; see retained reports' }
