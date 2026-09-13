param(
    [Parameter(Mandatory)][string]$ArtifactsDirectory,
    [Parameter(Mandatory)][string]$ReportsDirectory,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(?:-\d+)?$')][string]$ExpectedLibxml,
    [string]$ExpectedFailingCase,
    [int]$ExpectedFailureExitCode = 0
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ExpectedRuntimeLibxml = $ExpectedLibxml -replace '-\d+$', ''
New-Item $ReportsDirectory -ItemType Directory -Force | Out-Null
$zips = @(Get-ChildItem $ArtifactsDirectory -Recurse -File | Where-Object { $_.Name -match '^php-[0-9].*-(?:nts-)?Win32-vs18-(?:x64|x86)\.zip$' })
if ($zips.Count -ne 4) { throw "Expected four runtime archives, found $($zips.Count)" }
$seen = @{}
$failed = $false
foreach ($zip in $zips) {
    $arch = if ($zip.Name -match '-x64.zip$') { 'x64' } else { 'x86' }
    $ts = if ($zip.Name -match '-nts-') { 'nts' } else { 'ts' }
    $variant = "$arch-$ts"
    if ($seen.ContainsKey($variant)) { throw "Duplicate variant $variant" }
    $seen[$variant] = $true
    $root = Join-Path $env:RUNNER_TEMP "libxml2-$variant"
    try {
        Expand-Archive $zip.FullName -DestinationPath $root -Force
        $bomFiles = @(Get-ChildItem $root -Recurse -Filter '*.cdx.json')
        if ($bomFiles.Count -eq 0) { throw 'Missing CycloneDX SBOM' }
        $xmlComponents = @()
        foreach ($file in $bomFiles) {
            $bom = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $xmlComponents += @($bom.components | Where-Object { $_.name -eq 'libxml2' })
        }
        if ($xmlComponents.Count -eq 0) { throw 'Missing libxml2 inventory' }
        $componentVersions = @($xmlComponents.version | Sort-Object -Unique)
        $allowedVersions = @($ExpectedLibxml, $ExpectedRuntimeLibxml | Sort-Object -Unique)
        $unexpectedVersions = @($componentVersions | Where-Object { $_ -notin $allowedVersions })
        if ($unexpectedVersions.Count -gt 0) {
            throw "Unexpected libxml2 component(s): $($unexpectedVersions -join ', '); expected $($allowedVersions -join ' or ')"
        }
        foreach ($requiredVersion in $allowedVersions) {
            if ($requiredVersion -notin $componentVersions) { throw "Missing libxml2 component $requiredVersion" }
        }
        $env:EXPECTED_LIBXML_VERSION = $ExpectedRuntimeLibxml
        $phpArguments = @('-n', '-d', "extension_dir=$root\ext", '-d', 'extension=xsl', (Join-Path $PSScriptRoot '../tests/libxml2-security.php'))
        $casesJson = & "$root\php.exe" @phpArguments '--list'
        if ($LASTEXITCODE -ne 0) { throw "PHP startup failed for $variant, exit $LASTEXITCODE" }
        $cases = @($casesJson | ConvertFrom-Json)
        if ($cases.Count -ne 16) { throw "Expected 16 focused checks, found $($cases.Count)" }
        if ($ExpectedFailingCase -and $ExpectedFailingCase -notin $cases) {
            throw "Expected failing case $ExpectedFailingCase is not in the focused test list"
        }
        $caseReports = @()
        foreach ($case in $cases) {
            $output = & "$root\php.exe" @phpArguments $case 2>&1
            $exitCode = $LASTEXITCODE
            $caseReports += [PSCustomObject]@{ test = $case; exitCode = $exitCode; output = ($output | Out-String) }
            Write-Host "$variant $case exit=$exitCode"
        }
        $caseReports | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $ReportsDirectory "$variant.json")
        Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in '.dll', '.exe' } |
            Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content (Join-Path $ReportsDirectory "$variant-binary-hashes.json")
        $xmlComponents | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $ReportsDirectory "$variant-libxml-components.json")
        $failedReports = @($caseReports | Where-Object { $_.exitCode -ne 0 })
        if ($ExpectedFailingCase) {
            $expectedReports = @($caseReports | Where-Object { $_.test -eq $ExpectedFailingCase })
            if ($expectedReports.Count -ne 1) { throw "Expected one $ExpectedFailingCase result for $variant" }
            if ($expectedReports[0].exitCode -ne $ExpectedFailureExitCode) {
                throw "$ExpectedFailingCase returned $($expectedReports[0].exitCode) for $variant; expected $ExpectedFailureExitCode"
            }
            $unexpectedFailures = @($failedReports | Where-Object { $_.test -ne $ExpectedFailingCase })
            if ($unexpectedFailures.Count -gt 0) {
                throw "Unexpected runtime failure(s) for $variant`: $($unexpectedFailures.test -join ', ')"
            }
        } elseif ($failedReports.Count -gt 0) {
            throw "Runtime tests failed for $variant"
        }
    } catch {
        $failed = $true
        $_ | Out-String | Set-Content (Join-Path $ReportsDirectory "$variant-error.txt")
        Write-Host $_
    }
}
$zips | Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content (Join-Path $ReportsDirectory 'archive-hashes.json')
if ($failed) { throw 'One or more PHP artifact variants failed libxml2 validation' }
