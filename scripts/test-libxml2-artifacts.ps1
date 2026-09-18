param(
    [Parameter(Mandatory)][string]$ArtifactsDirectory,
    [Parameter(Mandatory)][string]$ReportsDirectory,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+(?:-\d+)?$')][string]$ExpectedLibxml,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedLibxmlCommit,
    [Parameter(Mandatory)][ValidateSet('vs16', 'vs17')][string]$ExpectedVs,
    [Parameter(Mandatory)][ValidatePattern('^8\.[2-5]$')][string]$ExpectedPhpSeries,
    [Parameter(Mandatory)][string]$ExpectedLibxmlArtifactDirectory,
    [Parameter(Mandatory)][string]$ExpectedLibxsltArtifactDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ExpectedRuntimeLibxml = $ExpectedLibxml -replace '-\d+$', ''
$ExpectedLibxslt = '1.1.43-2'
$ExpectedLibxsltCommit = '9f399f8d223ddddeaeacd15285a2e993ec326c0f'
New-Item $ReportsDirectory -ItemType Directory -Force | Out-Null
$zips = @(Get-ChildItem $ArtifactsDirectory -Recurse -File | Where-Object {
    $_.Name -match "^php-$([regex]::Escape($ExpectedPhpSeries))\.[0-9].*-(?:nts-)?Win32-$ExpectedVs-(?:x64|x86)\.zip$"
})
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
        if ($bomFiles.Count -ne 1) { throw "Expected one embedded CycloneDX SBOM, found $($bomFiles.Count)" }
        $vexFiles = @(Get-ChildItem $root -Recurse -Filter '*.openvex.json')
        if ($vexFiles.Count -ne 1) { throw "Expected one embedded OpenVEX document, found $($vexFiles.Count)" }
        $bom = Get-Content $bomFiles[0].FullName -Raw | ConvertFrom-Json
        $xmlComponents = @($bom.components | Where-Object { $_.name -eq 'libxml2' })
        $xsltComponents = @($bom.components | Where-Object { $_.name -eq 'libxslt' })
        if ($xmlComponents.Count -ne 1) { throw "Expected one libxml2 inventory component, found $($xmlComponents.Count)" }
        if ($xsltComponents.Count -ne 1) { throw "Expected one libxslt inventory component, found $($xsltComponents.Count)" }
        $xmlComponent = $xmlComponents[0]
        $xsltComponent = $xsltComponents[0]
        if ($xmlComponent.version -ne $ExpectedLibxml -or $xmlComponent.purl -ne "pkg:generic/libxml2@$ExpectedRuntimeLibxml") {
            throw 'Unexpected libxml2 component identity'
        }
        if ($xsltComponent.version -ne $ExpectedLibxslt -or $xsltComponent.purl -ne 'pkg:generic/libxslt@1.1.43') {
            throw 'Unexpected libxslt component identity'
        }
        $candidateXmlBomPath = Join-Path (Join-Path $ExpectedLibxmlArtifactDirectory $arch) 'share/sbom/libxml2.cdx.json'
        $candidateXsltBomPath = Join-Path (Join-Path $ExpectedLibxsltArtifactDirectory $arch) 'share/sbom/libxslt.cdx.json'
        if (-not (Test-Path $candidateXmlBomPath) -or -not (Test-Path $candidateXsltBomPath)) {
            throw 'Missing candidate package CycloneDX provenance'
        }
        $candidateXmlComponent = (Get-Content $candidateXmlBomPath -Raw | ConvertFrom-Json).metadata.component
        $candidateXsltComponent = (Get-Content $candidateXsltBomPath -Raw | ConvertFrom-Json).metadata.component
        if (($xmlComponent | ConvertTo-Json -Depth 100 -Compress) -ne ($candidateXmlComponent | ConvertTo-Json -Depth 100 -Compress)) {
            throw 'PHP libxml2 inventory does not exactly match the accepted candidate package'
        }
        if (($xsltComponent | ConvertTo-Json -Depth 100 -Compress) -ne ($candidateXsltComponent | ConvertTo-Json -Depth 100 -Compress)) {
            throw 'PHP libxslt inventory does not exactly match the accepted candidate package'
        }
        $xmlProperties = @{}; $xmlComponent.properties | ForEach-Object { $xmlProperties[$_.name] = $_.value }
        $xsltProperties = @{}; $xsltComponent.properties | ForEach-Object { $xsltProperties[$_.name] = $_.value }
        if ($xmlProperties['php:source-commit'] -ne $ExpectedLibxmlCommit -or
            $xmlProperties['php:source-ref'] -ne "libxml2-$ExpectedLibxml" -or
            $xmlProperties['php:vs'] -ne $ExpectedVs -or
            $xmlProperties['php:arch'] -ne $arch -or
            $xmlProperties['php:package-file-name'] -ne "libxml2-$ExpectedLibxml-$ExpectedVs-$arch.zip") {
            throw 'Unexpected libxml2 source or package provenance'
        }
        if ($xsltProperties['php:source-commit'] -ne $ExpectedLibxsltCommit -or
            $xsltProperties['php:source-ref'] -ne "libxslt-$ExpectedLibxslt" -or
            $xsltProperties['php:vs'] -ne $ExpectedVs -or
            $xsltProperties['php:arch'] -ne $arch -or
            $xsltProperties['php:package-file-name'] -ne "libxslt-$ExpectedLibxslt-$ExpectedVs-$arch.zip") {
            throw 'Unexpected libxslt source or package provenance'
        }
        $sidecarBomPath = "$($zip.FullName).cdx.json"
        $sidecarVexPath = "$($zip.FullName).openvex.json"
        if (-not (Test-Path $sidecarBomPath) -or -not (Test-Path $sidecarVexPath)) { throw 'Missing exported SBOM sidecars' }
        $sidecarBom = Get-Content $sidecarBomPath -Raw | ConvertFrom-Json
        foreach ($component in @($xmlComponent, $xsltComponent)) {
            $sidecarMatches = @($sidecarBom.components | Where-Object { $_.name -eq $component.name })
            if ($sidecarMatches.Count -ne 1 -or
                ($sidecarMatches[0] | ConvertTo-Json -Depth 100 -Compress) -ne ($component | ConvertTo-Json -Depth 100 -Compress)) {
                throw "Exported SBOM does not match embedded $($component.name) provenance"
            }
        }
        $vexStatements = @()
        foreach ($file in $vexFiles) {
            $vex = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $vexStatements += @($vex.statements)
        }
        foreach ($cve in @(
            'CVE-2026-86137', 'CVE-2026-86138', 'CVE-2026-86140',
            'CVE-2026-86141', 'CVE-2026-86142', 'CVE-2026-86143',
            'CVE-2026-86144'
        )) {
            if (-not @($vexStatements | Where-Object { $_.vulnerability.name -eq $cve -and $_.status -eq 'fixed' })) {
                throw "Missing fixed VEX statement for $cve"
            }
        }
        if (-not @($vexStatements | Where-Object {
            $_.vulnerability.name -eq 'CVE-2026-86139' -and
            $_.status -eq 'not_affected' -and
            $_.justification -eq 'inline_mitigations_already_exist'
        })) {
            throw 'Missing not_affected VEX statement for CVE-2026-86139'
        }
        foreach ($binary in @('libxml2.dll', 'libxslt.dll', 'libexslt.dll')) {
            if (Get-ChildItem $root -Recurse -File -Filter $binary) {
                throw "Unexpected shared $binary in statically linked PHP runtime"
            }
        }
        $env:EXPECTED_LIBXML_VERSION = $ExpectedRuntimeLibxml
        $phpArguments = @('-n', '-d', "extension_dir=$root\ext", '-d', 'extension=xsl', (Join-Path $PSScriptRoot '../tests/libxml2-security.php'))
        $casesJson = & "$root\php.exe" @phpArguments '--list'
        if ($LASTEXITCODE -ne 0) { throw "PHP startup failed for $variant, exit $LASTEXITCODE" }
        $cases = @($casesJson | ConvertFrom-Json)
        if ($cases.Count -ne 16) { throw "Expected 16 focused checks, found $($cases.Count)" }
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
        @($xmlComponent, $xsltComponent) | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $ReportsDirectory "$variant-xml-components.json")
        $vexStatements | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $ReportsDirectory "$variant-vex-statements.json")
        if (@($caseReports | Where-Object { $_.exitCode -ne 0 }).Count -gt 0) { throw "Runtime tests failed for $variant" }
    } catch {
        $failed = $true
        $_ | Out-String | Set-Content (Join-Path $ReportsDirectory "$variant-error.txt")
        Write-Host $_
    }
}
$zips | Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content (Join-Path $ReportsDirectory 'archive-hashes.json')
if ($failed) { throw 'One or more PHP artifact variants failed libxml2 validation' }
