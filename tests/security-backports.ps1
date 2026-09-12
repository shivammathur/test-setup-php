param([Parameter(Mandatory)][string]$ArtifactsDirectory, [Parameter(Mandatory)][string]$ReportsDirectory)
$ErrorActionPreference = 'Stop'
New-Item $ReportsDirectory -ItemType Directory -Force | Out-Null
$archives = @(Get-ChildItem $ArtifactsDirectory -Recurse -File | Where-Object { $_.Name -match '^php-(?!devel-pack-|debug-pack-|test-pack-).+?-Win32-v[sc]\d+-(?:x64|x86)\.zip$' })
if ($archives.Count -ne 4) { throw "Expected four PHP runtime ZIPs, found $($archives.Count)." }
$results = @()
foreach ($archive in $archives) {
    $root = Join-Path $env:RUNNER_TEMP ([guid]::NewGuid().ToString())
    try {
        Expand-Archive $archive.FullName $root
        $bom = Get-Content "$root/extras/sbom/php.cdx.json" -Raw | ConvertFrom-Json
        $vex = Get-Content "$root/extras/sbom/php.openvex.json" -Raw | ConvertFrom-Json
        $checks = @(@{ name = 'net-snmp'; commit = '2ef6429c7f820a25ddd653e8ee6ecd53f9208067'; ids = @('CVE-2020-15861') })
        if ($bom.metadata.component.version -like '8.2.*') {
            $checks += @{ name = 'ICU'; commit = '38b181c5322d0d28ace5951eafc8308933e7cbd9'; ids = @('CVE-2025-5222', 'OSV-2020-866', 'OSV-2020-867', 'OSV-2021-1236') }
        }
        $checkedIds = @()
        foreach ($check in $checks) {
            $component = @($bom.components | Where-Object { $_.name -eq $check.name -and @($_.properties | Where-Object { $_.name -eq 'php:source-commit' -and $_.value -eq $check.commit }).Count -eq 1 })
            if ($component.Count -ne 1) { throw "Missing expected source identity in PHP SBOM: $($check.name)" }
            foreach ($id in $check.ids) {
                $finding = @($bom.vulnerabilities | Where-Object { $_.id -eq $id -and $_.analysis.state -eq 'resolved' -and @($_.affects.ref) -contains $component[0].'bom-ref' })
                $statement = @($vex.statements | Where-Object { $_.vulnerability.name -eq $id -and $_.status -eq 'fixed' -and @($_.products.identifiers.purl) -contains $component[0].purl })
                if ($finding.Count -ne 1 -or $statement.Count -lt 1) { throw "CVE/OSV fix was lost during PHP SBOM/OpenVEX merge: $id" }
                $checkedIds += $id
            }
        }
        $mibs = "$root/mib-fixture"
        $persistent = "$root/persistent"
        New-Item $mibs, $persistent -ItemType Directory | Out-Null
        Copy-Item "$PSScriptRoot/SECURITY-TEST-MIB.txt" $mibs
        $env:MIBDIRS = $mibs
        $env:MIBS = 'ALL'
        $env:SNMP_PERSISTENT_DIR = $persistent
        $arguments = @('-n', '-d', "extension_dir=$root/ext", '-d', 'extension=snmp', '-d', 'extension=intl', "$PSScriptRoot/security-backports.php")
        $first = & "$root/php.exe" @arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "PHP backport runtime check failed: $first" }
        if (Test-Path "$persistent/mib_indexes") { throw 'PHP created a MIB index cache.' }
        New-Item "$persistent/mib_indexes" -ItemType Directory | Out-Null
        $index = "$persistent/mib_indexes/0"
        $sentinel = "DIR $mibs`nSENTINEL`n"
        [IO.File]::WriteAllText($index, $sentinel)
        $second = & "$root/php.exe" @arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "PHP with existing MIB index failed: $second" }
        if ([IO.File]::ReadAllText($index) -cne $sentinel) { throw 'PHP overwrote the existing MIB index.' }
        $results += @{ archive = $archive.Name; sha256 = (Get-FileHash $archive.FullName -Algorithm SHA256).Hash; passed = $true; sbomFixes = $checkedIds; first = @($first | ForEach-Object { "$_" }); second = @($second | ForEach-Object { "$_" }) }
        Write-Host "PASS: $($archive.Name) SNMP cache regression and Intl runtime"
    } finally {
        Remove-Item $root -Recurse -Force
    }
}
$results | ConvertTo-Json -Depth 10 | Set-Content "$ReportsDirectory/security-backports.json"
