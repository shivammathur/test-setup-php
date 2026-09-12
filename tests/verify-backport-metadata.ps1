param([Parameter(Mandatory)][string]$Arch)
$ErrorActionPreference = 'Stop'
$cases = @(
    @{ directory = 'net-snmp'; name = 'net-snmp'; tag = 'net-snmp-5.7.3-4'; commit = '2ef6429c7f820a25ddd653e8ee6ecd53f9208067'; fixes = @('CVE-2020-15861') },
    @{ directory = 'icu'; name = 'ICU'; tag = 'icu4c-71.1-2'; commit = '38b181c5322d0d28ace5951eafc8308933e7cbd9'; fixes = @('CVE-2025-5222', 'OSV-2020-866', 'OSV-2020-867', 'OSV-2021-1236') }
)
foreach ($case in $cases) {
    $bom = Get-Content "$($case.directory)/share/sbom/$($case.name).cdx.json" -Raw | ConvertFrom-Json
    $vex = Get-Content "$($case.directory)/share/sbom/$($case.name).openvex.json" -Raw | ConvertFrom-Json
    $component = $bom.metadata.component
    $properties = @{}
    foreach ($property in $component.properties) { $properties[$property.name] = $property.value }
    if ($component.name -ne $case.name -or $properties['php:source-commit'] -ne $case.commit -or $properties['php:input-version'] -ne $case.tag -or $properties['php:arch'] -ne $Arch -or $properties['php:vs'] -ne 'vs16') {
        throw "Unexpected source or package identity for $($case.name)."
    }
    foreach ($id in $case.fixes) {
        $finding = @($bom.vulnerabilities | Where-Object { $_.id -eq $id -and $_.analysis.state -in @('resolved', 'resolved_with_pedigree') -and @($_.affects.ref) -contains $component.'bom-ref' })
        $statement = @($vex.statements | Where-Object { $_.vulnerability.name -eq $id -and $_.status -eq 'fixed' -and @($_.products.identifiers.purl) -contains $component.purl })
        if ($finding.Count -ne 1 -or $statement.Count -ne 1) { throw "Missing exact-product fixed disposition: $($case.name) / $id" }
    }
    if ($case.name -eq 'net-snmp') {
        $finding = @($bom.vulnerabilities | Where-Object { $_.id -eq 'CVE-2025-68615' -and $_.analysis.state -eq 'not_affected' -and $_.analysis.justification -eq 'code_not_present' })
        if ($finding.Count -ne 1) { throw 'Existing snmptrapd disposition was lost.' }
    }
    Write-Host "PASS: $($case.name) $Arch source identity and fixed SBOM/OpenVEX dispositions"
}
