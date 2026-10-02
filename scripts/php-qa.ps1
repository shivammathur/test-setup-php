param([Parameter(Mandatory)][string]$Php)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$manifest = Get-Content php-matrix.json -Raw | ConvertFrom-Json
$rows = @($manifest.include | Where-Object { $_.php -eq $Php })
if ($rows.Count -ne 1) { throw 'Ambiguous PHP test entry' }
$row = $rows[0]
New-Item reports, artifacts, php-builds -ItemType Directory -Force | Out-Null
$headers = @{Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json'}
$api = 'https://api.github.com/repos/shivammathur/php-windows-builder'
$artifact = Invoke-RestMethod "$api/actions/artifacts/$($row.artifactId)" -Headers $headers
if ($artifact.expired -or $artifact.workflow_run.id -ne $row.run -or $artifact.name -ne 'artifacts') { throw 'Unexpected PHP artifact identity' }
Invoke-WebRequest "$api/actions/artifacts/$($row.artifactId)/zip" -Headers $headers -OutFile artifacts/php.zip
if ((Get-FileHash artifacts/php.zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $row.sha256) { throw 'PHP artifact ZIP hash mismatch' }
Expand-Archive artifacts/php.zip artifacts/files
$results = @()
foreach ($runtime in $row.runtimes) {
    $result = [ordered]@{archive=$runtime.name; run=$row.run; arch=$runtime.arch; ts=$runtime.ts; passed=$false}
    try {
        $zip = Join-Path artifacts/files $runtime.name
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $runtime.sha256) { throw 'PHP runtime ZIP hash mismatch' }
        $result.sha256 = $hash
        $dir = Join-Path (Resolve-Path php-builds).Path "$($runtime.arch)-$($runtime.ts)"
        Expand-Archive $zip $dir
        $exe = Join-Path $dir php.exe
        $ext = Join-Path $dir ext
        $base = @('-n', '-d', "extension_dir=$ext", '-d', 'extension=gd')
        $identity = & $exe @base -r 'echo json_encode(["version"=>PHP_VERSION,"bits"=>PHP_INT_SIZE*8,"zts"=>(bool)PHP_ZTS]);'
        if ($LASTEXITCODE -ne 0) { throw 'PHP/GD startup failed' }
        $identity = $identity | ConvertFrom-Json
        $bits = if ($runtime.arch -eq 'x64') {64} else {32}
        if ($identity.version -ne $runtime.version -or $identity.bits -ne $bits -or $identity.zts -ne ($runtime.ts -eq 'ts')) { throw 'PHP version/architecture/thread-safety mismatch' }
        $info = (& $exe @base --ri gd) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $info -notmatch '(?im)^libPNG Version\s*=>\s*1\.6\.59\s*$') { throw "GD does not report libpng 1.6.59: $info" }
        $info | Set-Content "reports/gd-$($runtime.arch)-$($runtime.ts).txt"
        foreach ($opcache in @($false, $true)) {
            $options = $base
            if ($opcache) {
                # PHP 8.5+ may compile opcache directly into the runtime.
                if (Test-Path "$ext/php_opcache.dll") { $options += @('-d', "zend_extension=$ext/php_opcache.dll") }
                $options += @('-d', 'opcache.enable_cli=1', '-d', 'opcache.jit=disable')
            } else { $options += @('-d', 'opcache.enable_cli=0') }
            $output = & $exe @options tests/php-gd.php
            if ($LASTEXITCODE -ne 0) { throw "GD runtime suite failed, opcache=$opcache" }
            $parsed = ($output -join "`n") | ConvertFrom-Json
            if ($parsed.checks.Count -lt 20) { throw 'Missing GD test coverage' }
            $output | Set-Content "reports/gd-$($runtime.arch)-$($runtime.ts)-opcache-$opcache.json"
        }
        $result.passed = $true
    } catch {
        $result.error = $_.ToString()
        Write-Host "::error::$($runtime.name): $_"
    } finally {
        $results += [pscustomobject]$result
        $results | ConvertTo-Json -Depth 20 | Set-Content reports/results.json
    }
}
if ($results.Count -ne 4 -or @($results | Where-Object { -not $_.passed }).Count) { throw 'PHP artifact QA failed' }
