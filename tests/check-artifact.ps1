param(
    [Parameter(Mandatory)][string] $Branch,
    [Parameter(Mandatory)][ValidateSet('x64', 'x86')][string] $Arch,
    [Parameter(Mandatory)][ValidateSet('ts', 'nts')][string] $Ts
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$results = (New-Item -ItemType Directory -Force results).FullName
$manifest = Get-Content (Join-Path $PSScriptRoot 'artifacts.json') -Raw | ConvertFrom-Json -AsHashtable
$source = $manifest[$Branch]
$variants = @($source.variants | Where-Object { $_.arch -eq $Arch -and $_.ts -eq $Ts })
if ($variants.Count -ne 1) { throw 'Expected exactly one accepted artifact' }
$expected = $variants[0]
$archive = Join-Path (Join-Path $PWD 'artifacts') $expected.name
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $expected.sha256) { throw 'PHP archive checksum differs from the accepted build' }
$package = Join-Path $env:RUNNER_TEMP "php-package-$Arch-$Ts"
Expand-Archive -LiteralPath $archive -DestinationPath $package
$inventory = @(Get-ChildItem $package -Recurse -File | ForEach-Object {
    [IO.Path]::GetRelativePath($package, $_.FullName).Replace('\', '/')
} | Sort-Object)
$inventory | Set-Content (Join-Path $results 'package-files.txt')
$dlls = @($inventory | Where-Object { $_ -match '(?i)\.dll$' })
$dlls | Set-Content (Join-Path $results 'package-dlls.txt')
if ($dlls | Where-Object { [IO.Path]::GetFileName($_) -match '(?i)(zstd|libzip|liblzma|zlib|libbz2).*\.dll$' }) {
    throw 'Unexpected compression DLL in the PHP package'
}
$dumpbin = & vswhere -latest -find 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' | Select-Object -Last 1
if (-not $dumpbin) { throw 'dumpbin was not found' }
$core = if ($Ts -eq 'ts') { 'php8ts.dll' } else { 'php8.dll' }
$allImports = @{}
foreach ($relative in @('php.exe', $core, 'ext/php_zip.dll')) {
    $output = & $dumpbin /DEPENDENTS (Join-Path $package $relative)
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect $relative" }
    $output | Set-Content (Join-Path $results ($relative.Replace('/', '-') + '-imports.txt'))
    $imports = @($output | Where-Object { $_ -match '^\s+[\w.-]+\.dll\s*$' } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if ($imports.Count -eq 0) { throw "No imports parsed for $relative" }
    $allImports[$relative] = $imports
    if ($imports | Where-Object { $_ -match '(?i)(zstd|libzip|lzma|zlib|bz2)' }) { throw "Unexpected compression dependency: $relative" }
}
$allowed = @($core.ToLowerInvariant(), 'kernel32.dll', 'advapi32.dll', 'bcrypt.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
foreach ($dependency in $allImports['ext/php_zip.dll']) {
    if ($dependency -notin $allowed -and $dependency -notmatch '^api-ms-win-(crt|core)-[\w-]+\.dll$') {
        throw "Unexpected php_zip.dll dependency: $dependency"
    }
}

$runtime = Join-Path $env:RUNNER_TEMP "php-isolated-$Arch-$Ts"
New-Item -ItemType Directory $runtime | Out-Null
foreach ($file in @('php.exe', $core, 'ext/php_zip.dll')) {
    Copy-Item (Join-Path $package $file) $runtime
}
# Both directories use the actual packaged binaries. The isolated directory has
# only PHP's executable/core and ZIP extension; its PATH contains only Windows.
$savedPath = $env:PATH
$savedLocation = Get-Location
$script = Join-Path $PSScriptRoot 'check-libzip.php'
$identityScript = Join-Path $PSScriptRoot 'check-identity.php'
$roundTrips = @()
try {
    foreach ($mode in @('package', 'isolated')) {
        $directory = if ($mode -eq 'package') { $package } else { $runtime }
        $extensions = if ($mode -eq 'package') { Join-Path $package 'ext' } else { $runtime }
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        Set-Location $directory
        $php = Join-Path $directory 'php.exe'
        $arguments = @('-n', '-d', "extension_dir=$extensions", '-d', 'extension=zip')
        $identity = & $php @arguments $identityScript $Branch $Arch $Ts
        if ($LASTEXITCODE -ne 0) { throw "$mode identity checks failed" }
        $identity | Set-Content (Join-Path $results "$mode-identity.json")
        $output = & $php @arguments $script 2>&1
        $exitCode = $LASTEXITCODE
        $output | Tee-Object -FilePath (Join-Path $results "$mode-roundtrips.txt")
        if ($exitCode -ne 0) { throw "$mode ZIP round trips failed" }
        if (@($output | Where-Object { $_ -match '^(store|deflate|bzip2|lzma|xz|zstd)-(plain|aes256): passed$' }).Count -ne 12) {
            throw "$mode did not report all 12 round trips"
        }
        if ($Branch -ne 'PHP-8.2' -and $output -notcontains 'torrentzip add/replace round trips: passed') {
            throw "$mode did not verify TorrentZip"
        }
        $roundTrips += @{mode=$mode; passed=12; torrentzip=($Branch -ne 'PHP-8.2')}
    }
} finally {
    $env:PATH = $savedPath
    Set-Location $savedLocation
}
$isolatedFiles = @(Get-ChildItem $runtime -File | Select-Object -ExpandProperty Name | Sort-Object)
if ($isolatedFiles.Count -ne 3) { throw 'Isolated runtime contains unexpected files' }
@{
    status='passed'; branch=$Branch; arch=$Arch; ts=$Ts; source_run=$source.run
    artifact=$expected.name; sha256=$hash; libzip='1.12'; source=$expected.libzip_source
    dlls=$dlls; imports=$allImports; isolated_files=$isolatedFiles; roundtrips=$roundTrips
} | ConvertTo-Json -Depth 10 | Tee-Object -FilePath (Join-Path $results 'result.json')
