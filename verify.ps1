param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$series = ($Version -split '\.')[0..1] -join '.'
$expected = (Get-Content expected.json -Raw | ConvertFrom-Json).$series
$root = Join-Path $env:LOCALAPPDATA 'Programs\PHP'
$install = Join-Path $root "$($expected.package)\nts\x64"
$current = Join-Path $root 'current'
$php = Join-Path $current 'php.exe'
if (!(Test-Path $php)) { throw "Missing installed PHP: $php" }
if ((Get-Item $current).LinkType -ne 'Junction') { throw 'The current link is not a junction' }
if ((Get-Item $current).Target -notcontains $install) { throw 'The current link points to the wrong build' }
if (([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')[0] -ne $current) {
    throw 'The installer did not put the current link first in the user PATH'
}

$checked = 0
foreach ($file in $expected.files.PSObject.Properties) {
    $path = Join-Path $install $file.Name
    if (!(Test-Path -LiteralPath $path)) { throw "Missing package file: $path" }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.Value) {
        throw "Installed file differs from audited numbered artifact: $path"
    }
    $checked++
}

$env:EXPECTED_RUNTIME = $expected.runtime
$env:EXPECTED_INI = Join-Path $install 'php.ini'
& $php -v
if ($LASTEXITCODE -ne 0) { throw 'php -v failed' }
& $php -d extension=curl smoke.php | Tee-Object evidence/runtime.json
if ($LASTEXITCODE -ne 0) { throw 'Runtime checks failed' }
$result = [ordered]@{
    requested = $Version
    package = $expected.package
    runtime = $expected.runtime
    installed = $install
    verified_files = $checked
    source_zip_sha256 = $expected.zip_sha256
}
$result | ConvertTo-Json | Tee-Object evidence/result.json
