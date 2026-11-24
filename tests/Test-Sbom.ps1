param([switch]$Reference)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'results'
$cases = @(
    @{ Version='8.2'; Source='php-82' },
    @{ Version='8.7'; Source='php-master' },
    @{ Version='master'; Source='php-master' }
)
if ($Reference) {
    if ($PSVersionTable.PSVersion.Major -ne 7) { throw 'Reference must use PowerShell 7' }
    . (Join-Path $root 'base/php/BuildPhp/public/New-PhpSbomMetadata.ps1')
    foreach ($case in $cases) {
        New-PhpSbomMetadata -PhpVersion $case.Version -SourceDirectory (Join-Path $root $case.Source) -OutputPath (Join-Path $out "base-$($case.Version).json")
    }
    return
}
if ($PSVersionTable.PSVersion.Major -ne [int]$env:EXPECTED_PS_MAJOR) { throw 'Unexpected PowerShell version' }
Import-Module (Join-Path $root 'builder/php/BuildPhp/BuildPhp.psd1') -Force -DisableNameChecking
$config = Get-Content (Join-Path $root 'builder/php/BuildPhp/config/sbom.json') -Raw | ConvertFrom-Json
$results = foreach ($case in $cases) {
    $version = $case.Version
    $file = Join-Path $out "head-$version.json"
    BuildPhp\New-PhpSbomMetadata -PhpVersion $version -SourceDirectory (Join-Path $root $case.Source) -OutputPath $file
    $expected = Get-Content (Join-Path $out "base-$version.json") -Raw | ConvertFrom-Json
    $actual = Get-Content $file -Raw | ConvertFrom-Json
    if (($actual | ConvertTo-Json -Depth 20 -Compress) -cne ($expected | ConvertTo-Json -Depth 20 -Compress)) { throw "SBOM mismatch: $version" }
    $expectedNames = @($config.components | Where-Object { $_.name -notin $config.php.$version.exclude }).name
    if (($actual.components.name -join ',') -cne ($expectedNames -join ',')) { throw "SBOM component mismatch: $version" }
    foreach ($override in $config.php.$version.overrides.PSObject.Properties) {
        foreach ($property in $override.Value.PSObject.Properties) {
            $component = $actual.components | Where-Object { $_.name -eq $override.Name }
            if ($component.($property.Name) -cne $property.Value) { throw "Incorrect override for $($override.Name)" }
        }
    }
    [pscustomobject]@{ version=$version; components=@($actual.components).Count; result='pass' }
}
Remove-Module BuildPhp
$baselineFailures = @()
if ($PSVersionTable.PSVersion.Major -eq 5) {
    . (Join-Path $root 'base/php/BuildPhp/public/New-PhpSbomMetadata.ps1')
    foreach ($case in $cases) {
        $failure = $null
        try { New-PhpSbomMetadata -PhpVersion $case.Version -SourceDirectory (Join-Path $root $case.Source) -OutputPath (Join-Path $out "unexpected-base-$($case.Version).json") } catch { $failure=$_.Exception.Message }
        if (-not $failure -or $failure -notmatch 'ChildPath') { throw "Expected baseline ChildPath failure for $($case.Version), got: $failure" }
        $baselineFailures += @{ version=$case.Version; error=$failure }
    }
}
[ordered]@{ powershell=$PSVersionTable.PSVersion.ToString(); results=$results; baselineFailures=$baselineFailures } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $out 'sbom-results.json') -Encoding UTF8
Write-Host "SBOM cases passed: $($results.Count); baseline failures reproduced: $($baselineFailures.Count)"
