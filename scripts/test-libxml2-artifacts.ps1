param(
    [Parameter(Mandatory)][string]$ArtifactsDirectory,
    [Parameter(Mandatory)][string]$ReportsDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
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
        foreach ($component in $xmlComponents) {
            if ($component.version -ne '2.15.4') { throw "Stale libxml2 component: $($component.version)" }
        }
        $args = @('-n', '-d', "extension_dir=$root\ext", '-d', 'extension=xsl', (Join-Path $PSScriptRoot '../tests/libxml2-security.php'))
        & "$root\php.exe" @args | Tee-Object -FilePath (Join-Path $ReportsDirectory "$variant.json")
        if ($LASTEXITCODE -ne 0) { throw "Runtime tests failed for $variant" }
        Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in '.dll', '.exe' } |
            Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content (Join-Path $ReportsDirectory "$variant-binary-hashes.json")
        $xmlComponents | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $ReportsDirectory "$variant-libxml-components.json")
    } catch {
        $failed = $true
        $_ | Out-String | Set-Content (Join-Path $ReportsDirectory "$variant-error.txt")
        Write-Host $_
    }
}
$zips | Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content (Join-Path $ReportsDirectory 'archive-hashes.json')
if ($failed) { throw 'One or more PHP artifact variants failed libxml2 validation' }
