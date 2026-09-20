param(
    [Parameter(Mandatory)][ValidateSet('8.0', '8.1', '8.2', '8.3', '8.4', '8.5')][string]$PhpVersion,
    [Parameter(Mandatory)][ValidateSet('x64', 'x86')][string]$Arch,
    [Parameter(Mandatory)][ValidateSet('nts', 'ts')][string]$ThreadSafety,
    [ValidateSet('bundled', 'vs18')][string]$OpenBlas = 'bundled'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = (Get-Location).Path
New-Item validation -ItemType Directory -Force | Out-Null
$manifest = Get-Content qa/artifacts.json -Raw | ConvertFrom-Json
$vs = if ([version]$PhpVersion -lt [version]'8.4') { 'vs16' } else { 'vs17' }
$name = "php_tensor-3.1.0-$PhpVersion-$ThreadSafety-$vs-$Arch.zip"
$expected = @($manifest.tensor | Where-Object name -eq $name)
$archives = @(Get-ChildItem artifacts/tensor/3.1.0 -File -Filter $name)
if ($archives.Count -ne 1 -or $expected.Count -ne 1) { throw "Expected exactly one $name" }
$archiveHash = (Get-FileHash $archives[0].FullName).Hash.ToLowerInvariant()
if ($archiveHash -ne $expected[0].sha256) { throw 'Tensor ZIP differs from the original build artifact' }
Expand-Archive $archives[0].FullName validation/tensor
$tensorDll = Get-Item validation/tensor/php_tensor.dll
$tensorHash = (Get-FileHash $tensorDll.FullName).Hash.ToLowerInvariant()
if ($tensorHash -ne $expected[0].tensor_sha256) { throw 'Tensor DLL differs from the original build artifact' }

function Get-OpenBlasPackage([string]$Toolset) {
    $package = @($manifest.openblas | Where-Object { $_.vs -eq $Toolset -and $_.arch -eq $Arch })
    if ($package.Count -ne 1) { throw "Missing OpenBLAS manifest for $Toolset/$Arch" }
    $package = $package[0]
    $zip = "$root/validation/$($package.name)"
    Invoke-WebRequest $package.url -OutFile $zip -MaximumRetryCount 3
    if ((Get-FileHash $zip).Hash.ToLowerInvariant() -ne $package.sha256) { throw 'Public OpenBLAS ZIP differs from the tested release' }
    $directory = "$root/validation/openblas-$Toolset"
    Expand-Archive $zip $directory
    $dll = "$directory/bin/libopenblas.dll"
    if ((Get-FileHash $dll).Hash.ToLowerInvariant() -ne $package.dll_sha256) { throw 'Unexpected OpenBLAS DLL' }
    return [PSCustomObject]@{ directory = $directory; dll = $dll; manifest = $package }
}

$bundled = Get-OpenBlasPackage $vs
$bundledHash = (Get-FileHash validation/tensor/libopenblas.dll).Hash.ToLowerInvariant()
if ($bundledHash -ne $bundled.manifest.dll_sha256) { throw 'Tensor was not packaged with the published OpenBLAS 0.3.34 build' }
foreach ($license in Get-ChildItem "$($bundled.directory)/share/licenses" -Recurse -File) {
    if ((Get-FileHash "validation/tensor/$($license.Name)").Hash -ne (Get-FileHash $license.FullName).Hash) {
        throw "Tensor lost or changed $($license.Name)"
    }
}
$target = $bundled
if ($OpenBlas -eq 'vs18') {
    if ($PhpVersion -ne '8.5') { throw 'VS18 dependency checks use the existing PHP 8.5 Tensor builds' }
    $target = Get-OpenBlasPackage 'vs18'
    # Same OpenBLAS version/exports; do not rebuild or alter the Tensor DLL.
    Copy-Item $target.dll validation/tensor/libopenblas.dll -Force
}

# Reuse the builder's PHP resolver/downloader for the exact architecture and ZTS ABI.
Import-Module ./php-windows-builder/extension/BuildPhpExtension/BuildPhpExtension.psm1 -DisableNameChecking
$config = [PSCustomObject]@{ php_version = $PhpVersion; arch = $Arch; ts = $ThreadSafety; vs_version = $vs }
New-Item validation/runtime -ItemType Directory -Force | Out-Null
Push-Location validation/runtime
try {
    $details = Get-PhpBuildDetails -Config $config
    Get-PhpBuild -Config $config -BuildDetails $details | Out-Null
} finally { Pop-Location }
$phpDirectory = (Resolve-Path validation/runtime/php-bin).Path
$php = "$phpDirectory/php.exe"
Copy-Item $target.dll "$phpDirectory/libopenblas.dll" -Force
$runtime = & $php -n -r 'echo json_encode(["version" => PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION, "bits" => PHP_INT_SIZE * 8, "zts" => PHP_ZTS]);'
if ($LASTEXITCODE) { throw 'PHP runtime failed to start' }
$runtime = $runtime | ConvertFrom-Json
if ($runtime.version -ne $PhpVersion -or $runtime.bits -ne $(if ($Arch -eq 'x64') { 64 } else { 32 }) -or [bool]$runtime.zts -ne ($ThreadSafety -eq 'ts')) {
    throw 'PHP runtime does not match the Tensor artifact ABI'
}

Invoke-WebRequest https://phar.phpunit.de/phpunit-9.6.36.phar -OutFile validation/phpunit.phar -MaximumRetryCount 3
if ((Get-FileHash validation/phpunit.phar).Hash.ToLowerInvariant() -ne 'd9552a130747f02f9d7fc2427b143189c638e273c502c8faa88ab6b04c5f2662') {
    throw 'PHPUnit checksum mismatch'
}
$provenance = [ordered]@{
    source_run = $manifest.source_run
    source_artifact_sha256 = $manifest.source_artifact_sha256
    tensor_zip = $name
    tensor_zip_sha256 = $archiveHash
    tensor_dll_sha256 = $tensorHash
    tensor_source_commit = '94cd025562b4edcd968e1c26b67a8751cb42f39a'
    php = $runtime
    bundled_openblas_sha256 = $bundledHash
    tested_openblas = $target.manifest
    mode = $OpenBlas
}
$provenance | ConvertTo-Json -Depth 6 | Tee-Object validation/provenance.json | Write-Host
$arguments = @('-n', '-d', "extension_dir=$phpDirectory/ext", '-d', 'extension=mbstring', '-d', "extension=$($tensorDll.FullName)")
$env:TENSOR_EXPECTED_VERSION = $manifest.runtime_version
& $php @arguments --ri tensor 2>&1 | Tee-Object validation/tensor-info.txt
if ($LASTEXITCODE) { throw 'Tensor failed to load' }
& $php @arguments validation/phpunit.phar --no-configuration --bootstrap qa/bootstrap.php --log-junit validation/phpunit.xml tensor-tests/tests 2>&1 | Tee-Object validation/phpunit.txt
if ($LASTEXITCODE) { throw 'Tensor PHPUnit tests failed' }
[xml]$report = Get-Content validation/phpunit.xml -Raw
$cases = @($report.SelectNodes('//testcase'))
$skips = @($report.SelectNodes('//testcase/skipped')).Count
$failures = @($report.SelectNodes('//testcase/failure | //testcase/error')).Count
if ($cases.Count -lt 300 -or $cases.Count -le $skips -or $failures) { throw 'Missing, incomplete or failing PHPUnit suite' }
if ((Get-FileHash $tensorDll.FullName).Hash.ToLowerInvariant() -ne $tensorHash) { throw 'Tensor DLL changed during validation' }
$assertions = ($cases | ForEach-Object { [int]$_.assertions } | Measure-Object -Sum).Sum
$result = [ordered]@{ tests = $cases.Count; assertions = $assertions; skipped = $skips; failures = $failures }
$result | ConvertTo-Json | Tee-Object validation/result.json | Write-Host
"PASS: $name with $($target.manifest.name): $($cases.Count) tests, $assertions assertions, $skips skips, no failures." | Tee-Object validation/result.txt | Write-Host
