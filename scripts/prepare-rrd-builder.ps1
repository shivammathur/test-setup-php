param([Parameter(Mandatory)][string]$Php, [Parameter(Mandatory)][string]$Arch, [Parameter(Mandatory)][string]$Ts)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$artifactDirectory = (Resolve-Path php-artifacts).Path
$runtime = @(Get-ChildItem $artifactDirectory -Filter '*.zip' -File | Where-Object {
    $_.Name -match "^php-(?!debug-pack-|devel-pack-|test-pack-).+?-(?:nts-)?Win32-vs\d+-$Arch\.zip$" -and
    ($_.Name.Contains('-nts-') -eq ($Ts -eq 'nts'))
})
if ($runtime.Count -ne 1) { throw 'Expected exactly one candidate PHP runtime' }
$match = [regex]::Match($runtime[0].Name, '^php-(.+?)-(?:nts-)?Win32-vs\d+-(?:x64|x86)\.zip$')
$version = $match.Groups[1].Value
"QA_PHP_ARTIFACTS=$artifactDirectory" >> $env:GITHUB_ENV
"QA_PHP_VERSION=$version" >> $env:GITHUB_ENV
foreach ($name in @($runtime[0].Name, $runtime[0].Name.Replace('php-', 'php-devel-pack-'))) {
    if (!(Test-Path (Join-Path $artifactDirectory $name))) { throw "Missing candidate archive: $name" }
}
$private = 'builder/extension/BuildPhpExtension/private'
# Route the builder's runtime and SDK requests to these exact candidate archives.
@'
function Get-PhpBuildDetails {
    param([PSCustomObject]$Config)
    return [PSCustomObject]@{phpSemver=$env:QA_PHP_VERSION; baseUrl='https://candidate.invalid'; fallbackBaseUrl='https://candidate.invalid'}
}
'@ | Set-Content "$private/Get-PhpBuildDetails.ps1"
$file = "$private/Get-File.ps1"
$content = Get-Content $file -Raw
$needle = '    for ($i = 0; $i -lt $Retries; $i++) {'
if (!$content.Contains($needle)) { throw 'Builder Get-File integration changed' }
$replacement = @'
    if ($Url.StartsWith('https://candidate.invalid/')) {
        if (!$OutFile) { throw 'Candidate PHP requests must write a file' }
        $source = Join-Path $env:QA_PHP_ARTIFACTS ([IO.Path]::GetFileName($Url))
        Copy-Item -LiteralPath $source -Destination $OutFile
        return
    }
'@
$content.Replace($needle, "$replacement`n$needle") | Set-Content $file
$file = "$private/Add-Dependencies.ps1"
$content = Get-Content $file -Raw
$needle = '        Add-ExtensionDependencies -Config $Config'
if (!$content.Contains($needle)) { throw 'Builder dependency integration changed' }
$replacement = @'
        Copy-Item "$env:QA_LIBRARY_DEPS/*" ../deps -Recurse -Force
        Copy-Item "$env:QA_LIBRARY_DEPS/bin/*.dll" $Prefix -Force
        "QA_RRD_PHP=$Prefix/php.exe" >> $env:GITHUB_ENV
        "QA_RRD_ROOT=$((Get-Location).Path)" >> $env:GITHUB_ENV
'@
$content.Replace($needle, "$needle`n$replacement") | Set-Content $file
$file = "$private/Invoke-Tests.ps1"
$content = Get-Content $file -Raw
$needle = '                Invoke-Expression $phpExpression'
if (!$content.Contains($needle)) { throw 'Builder test integration changed' }
$replacement = @'
                $env:TEST_PHP_JUNIT = "C:\rrd-build\rrd-junit-$opcacheMode.xml"
'@
$content.Replace($needle, "$replacement`n$needle") | Set-Content $file
git -C builder diff | Set-Content reports/builder-candidate-overrides.diff
