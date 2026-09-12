param([Parameter(Mandatory)][string]$BuilderRoot)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path $BuilderRoot).Path
$temporary = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item "$temporary/metadata/libraries" -ItemType Directory -Force | Out-Null

# Isolate the generator's SPDX license-list lookup from the network.
function Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec)
    if ($Uri -ne 'https://spdx.org/licenses/licenses.json') { throw "Unexpected HTTP request: $Uri" }
    return @{ licenseListVersion = '3.27.0' }
}

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if (($Actual | ConvertTo-Json -Depth 20 -Compress) -cne ($Expected | ConvertTo-Json -Depth 20 -Compress)) {
        throw "$Label mismatch: $Actual / $Expected"
    }
}

try {
    Copy-Item "$repository/sbom/schema.json", "$repository/sbom/document.json" "$temporary/metadata/"
    $cve = @{ id = 'CVE-2020-15861'; source = 'NVD'; url = 'https://nvd.nist.gov/vuln/detail/CVE-2020-15861'; detail = 'Legacy CVE fix.' }
    $osv = @{ id = 'OSV-2020-866'; source = 'OSV'; url = 'https://osv.dev/vulnerability/OSV-2020-866'; detail = 'OSV fix.' }
    $cases = @(
        @{ name = 'legacy'; fixedCves = @($cve); fixedVulnerabilities = @(); expected = @($cve) },
        @{ name = 'osv'; fixedCves = @(); fixedVulnerabilities = @($osv); expected = @($osv) },
        @{ name = 'mixed'; fixedCves = @($cve); fixedVulnerabilities = @($osv); expected = @($cve, $osv) }
    )
    foreach ($case in $cases) {
        $metadata = @{
            component = 'sbom-fixture'
            version = @{ stripPrefixes = @('sbom-fixture-') }
            upstream = @{ repository = 'example/sbom-fixture'; tagTemplate = 'v{version}' }
            license = @{ id = 'MIT' }
            purl = 'pkg:generic/sbom-fixture@{upstreamVersion}'
            patchedBuilds = @(@{
                tag = 'sbom-fixture-1.0.0-1'
                upstream = @{ repository = 'example/sbom-fixture'; tag = 'v1.0.0'; version = '1.0.0' }
                fork = @{ repository = 'winlibs/sbom-fixture'; tag = 'sbom-fixture-1.0.0-1' }
                fixedCves = $case.fixedCves
                fixedVulnerabilities = $case.fixedVulnerabilities
            })
        }
        $json = $metadata | ConvertTo-Json -Depth 30
        if (-not ($json | Test-Json -SchemaFile "$temporary/metadata/schema.json")) { throw 'Fixture schema failed.' }
        $json | Set-Content "$temporary/metadata/libraries/sbom-fixture.json"
        $install = "$temporary/$($case.name)"
        & "$repository/scripts/generate-sbom.ps1" -Library sbom-fixture -Version sbom-fixture-1.0.0-1 -InstallRoot $install -MetadataPath "$temporary/metadata" -Vs vs16 -Arch x64 -PhpVersion 8.2
        $bom = Get-Content "$install/share/sbom/sbom-fixture.cdx.json" -Raw | ConvertFrom-Json
        $vex = Get-Content "$install/share/sbom/sbom-fixture.openvex.json" -Raw | ConvertFrom-Json
        Assert-Equal @($bom.vulnerabilities.id) @($case.expected.id) 'Advisory IDs'
        Assert-Equal @($bom.vulnerabilities.source.name) @($case.expected.source) 'Advisory sources'
        Assert-Equal @($bom.metadata.component.pedigree.patches.resolves.id) @($case.expected.id) 'Pedigree IDs'
        Assert-Equal @($vex.statements.vulnerability.name) @($case.expected.id) 'OpenVEX IDs'
        foreach ($vulnerability in $bom.vulnerabilities) {
            Assert-Equal $vulnerability.analysis.state 'resolved_with_pedigree' 'CycloneDX state'
            Assert-Equal @($vulnerability.affects.ref) @($bom.metadata.component.'bom-ref') 'Affected product'
        }
        foreach ($statement in $vex.statements) {
            Assert-Equal $statement.status 'fixed' 'OpenVEX status'
            Assert-Equal $statement.products[0].identifiers.purl 'pkg:generic/sbom-fixture@1.0.0' 'OpenVEX PURL'
        }
        Write-Host "PASS: $($case.name)"
    }
    $metadata.patchedBuilds[0].fixedVulnerabilities[0].id = ''
    $invalid = $metadata | ConvertTo-Json -Depth 30
    if ($invalid | Test-Json -SchemaFile "$temporary/metadata/schema.json" -ErrorAction SilentlyContinue) { throw 'Empty advisory ID was accepted.' }
    Write-Host 'PASS: invalid advisory ID rejected'
} finally {
    Remove-Item $temporary -Recurse -Force
}
