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
        $results += @{ archive = $archive.Name; sha256 = (Get-FileHash $archive.FullName -Algorithm SHA256).Hash; passed = $true; first = @($first | ForEach-Object { "$_" }); second = @($second | ForEach-Object { "$_" }) }
        Write-Host "PASS: $($archive.Name) SNMP cache regression and Intl runtime"
    } finally {
        Remove-Item $root -Recurse -Force
    }
}
$results | ConvertTo-Json -Depth 10 | Set-Content "$ReportsDirectory/security-backports.json"
