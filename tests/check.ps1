param([string]$Branch, [string]$Arch, [string]$Ts)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content (Join-Path $PSScriptRoot 'artifacts.json') -Raw | ConvertFrom-Json -AsHashtable
$expected = @($manifest[$Branch].variants | Where-Object { $_.arch -eq $Arch -and $_.ts -eq $Ts })
if ($expected.Count -ne 1) { throw 'Expected exactly one accepted package' }
$archive = Join-Path (Join-Path $PWD 'artifacts') $expected[0].name
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $expected[0].sha256) { throw 'Package hash mismatch' }
$results = (New-Item -ItemType Directory results).FullName
$package = Join-Path $env:RUNNER_TEMP 'php-package'
Expand-Archive $archive $package
$php = Join-Path $package 'php.exe'
$all = @()
foreach ($test in @('password_get_info', 'password_needs_rehash')) {
    $text = Get-Content (Join-Path $PSScriptRoot "$Branch/$test.phpt") -Raw
    if ($text -match '--(?:SKIPIF|INI|EXPECTF|EXPECTREGEX)--') { throw 'Unsupported PHPT section' }
    $match = [regex]::Match($text, '(?s)--FILE--\r?\n(.*?)--EXPECT--\r?\n(.*)')
    if (-not $match.Success) { throw 'Invalid PHPT format' }
    $script = Join-Path $results "$test.php"
    $match.Groups[1].Value.Replace('<?php', '<?php if (extension_loaded("zip")) { throw new RuntimeException("ZIP must not be loaded"); }') | Set-Content $script -Encoding utf8NoBOM
    $output = & $php -n $script 2>&1
    $exitCode = $LASTEXITCODE
    $actual = ($output -join "`n").Trim().Replace("`r`n", "`n")
    $expectedOutput = $match.Groups[2].Value.Trim().Replace("`r`n", "`n")
    $actual | Set-Content (Join-Path $results "$test.out")
    if ($exitCode -ne 0 -or $actual -cne $expectedOutput) { throw "$test failed its source-matched expectation" }
    $all += $test
    Write-Host "${test}: passed (ZIP disabled)"
}
@{status='passed'; branch=$Branch; arch=$Arch; ts=$Ts; sha256=$hash; zip_loaded=$false; passed=$all} | ConvertTo-Json | Tee-Object -FilePath (Join-Path $results 'result.json')
