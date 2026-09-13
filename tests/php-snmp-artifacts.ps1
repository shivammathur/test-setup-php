param(
    [Parameter(Mandatory)][string]$ArtifactsDirectory,
    [Parameter(Mandatory)][string]$PhpTarget,
    [Parameter(Mandatory)][string]$PackagePhpTarget,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$ReportsDirectory
)

$ErrorActionPreference = 'Stop'
New-Item -Path $ReportsDirectory -ItemType Directory -Force | Out-Null
$archives = @(Get-ChildItem -LiteralPath $ArtifactsDirectory -Recurse -File | Where-Object {
    $_.Name -match '^php-(?!devel-pack-|debug-pack-|test-pack-).+?-(?:nts-)?Win32-v[sc]\d+-(?:x64|x86)\.zip$'
})
if ($archives.Count -ne 4) { throw "Expected four PHP runtime ZIPs, found $($archives.Count)." }

$results = @()
foreach ($archive in $archives) {
    $root = Join-Path $env:RUNNER_TEMP ([guid]::NewGuid().ToString())
    try {
        Expand-Archive -LiteralPath $archive.FullName -DestinationPath $root
        $cdx = Get-Content -LiteralPath (Join-Path $root 'extras\sbom\php.cdx.json') -Raw | ConvertFrom-Json -Depth 100
        $vex = Get-Content -LiteralPath (Join-Path $root 'extras\sbom\php.openvex.json') -Raw | ConvertFrom-Json -Depth 100
        $components = @($cdx.components | Where-Object { $_.name -eq 'net-snmp' -and $_.version -eq '5.9.4-2' })
        if ($components.Count -ne 1) { throw "Missing exact Net-SNMP component in $($archive.Name)." }
        $component = $components[0]
        if ($archive.Name -notmatch '-(?<arch>x64|x86)\.zip$') {
            throw "Unable to determine architecture for $($archive.Name)."
        }
        $arch = $Matches.arch
        $properties = @{}
        foreach ($property in @($component.properties)) { $properties[$property.name] = $property.value }
        $expectedPackage = "net-snmp-5.9.4-2-vs17-$arch.zip"
        $expectedUrl = "https://downloads.php.net/~windows/php-sdk/deps/vs17/$arch/$expectedPackage"
        $distribution = @($component.externalReferences | Where-Object {
            $_.type -eq 'distribution' -and $_.url -eq $expectedUrl
        })
        if ($properties['php:php-version'] -ne $PackagePhpTarget -or
            $properties['php:arch'] -ne $arch -or
            $properties['php:package-file-name'] -ne $expectedPackage -or
            $properties['php:download-location'] -ne $expectedUrl -or
            $distribution.Count -ne 1) {
            throw "Net-SNMP published-package provenance is incomplete in $($archive.Name)."
        }
        $sourceCommit = @($component.properties | Where-Object {
            $_.name -eq 'php:source-commit' -and $_.value -eq '7662537b29b1e278c65ab786ac4641cd6fb5b9d4'
        })
        if ($sourceCommit.Count -ne 1) { throw "Missing Net-SNMP source commit in $($archive.Name)." }
        $finding = @($cdx.vulnerabilities | Where-Object {
            $_.id -eq 'CVE-2026-89147' -and
            @('resolved', 'resolved_with_pedigree') -contains $_.analysis.state -and
            @($_.affects.ref) -contains $component.'bom-ref'
        })
        $statement = @($vex.statements | Where-Object {
            $_.vulnerability.name -eq 'CVE-2026-89147' -and $_.status -eq 'fixed'
        })
        if ($finding.Count -ne 1 -or $statement.Count -lt 1) {
            throw "CVE-2026-89147 metadata was lost while composing $($archive.Name)."
        }

        $php = Join-Path $root 'php.exe'
        $code = 'if (!extension_loaded("snmp")) { throw new Exception("SNMP extension missing"); } $s = new SNMP(SNMP::VERSION_2c, "127.0.0.1", "public", 10000, 0); if (!$s->close()) { throw new Exception("SNMP close failed"); } echo json_encode(["php" => PHP_VERSION, "snmp" => "passed"]), PHP_EOL;'
        $runtime = & $php -n -d "extension_dir=$root\ext" -d extension=snmp -r $code 2>&1
        if ($LASTEXITCODE -ne 0) { throw "SNMP runtime failed for $($archive.Name): $runtime" }

        $results += [ordered]@{
            archive = $archive.Name
            archiveSha256 = (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash
            snmpDllSha256 = (Get-FileHash -LiteralPath (Join-Path $root 'ext\php_snmp.dll') -Algorithm SHA256).Hash
            php = $PhpTarget
            packagePhp = $PackagePhpTarget
            packageFile = $expectedPackage
            packageUrl = $expectedUrl
            sourceRun = $RunId
            sourceCommit = $sourceCommit[0].value
            cve = $finding[0].analysis.state
            vex = $statement[0].status
            runtime = @($runtime | ForEach-Object { "$_" })
        }
        Write-Host "PASS: $($archive.Name) SNMP runtime and composed security metadata"
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}
$results | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ReportsDirectory 'php-artifacts.json')
