param(
    [Parameter(Mandatory)] [string] $Php
)

$ErrorActionPreference = 'Stop'
$manifest = Get-Content qa-manifest.json -Raw | ConvertFrom-Json
$row = @($manifest.php | Where-Object php -EQ $Php)
if ($row.Count -ne 1) { throw "Expected exactly one manifest entry for PHP $Php" }
$row = $row[0]
New-Item reports, artifacts, php-builds -ItemType Directory -Force | Out-Null
Start-Transcript -Path reports/qa-transcript.txt

$headers = @{
    Authorization = "Bearer $env:GH_TOKEN"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$api = 'https://api.github.com/repos/shivammathur/php-windows-builder'
$artifact = Invoke-RestMethod "$api/actions/artifacts/$($row.artifactId)" -Headers $headers
if ($artifact.expired -or $artifact.workflow_run.id -ne $row.runId -or $artifact.name -ne 'artifacts') {
    throw 'PHP artifact identity does not match the pinned source run'
}
Invoke-WebRequest "$api/actions/artifacts/$($row.artifactId)/zip" -Headers $headers -OutFile artifacts/merged.zip
$actualArchiveHash = (Get-FileHash artifacts/merged.zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualArchiveHash -ne $row.artifactSha256) { throw 'Merged PHP artifact SHA-256 mismatch' }
Expand-Archive artifacts/merged.zip artifacts/runtime
$mibs = $row.mibsPackage
$mibsApi = 'https://api.github.com/repos/winlibs/winlib-builder'
$mibsMetadata = Invoke-RestMethod "$mibsApi/actions/artifacts/$($mibs.artifactId)" -Headers $headers
if ($mibsMetadata.expired -or $mibsMetadata.workflow_run.id -ne $mibs.runId -or $mibsMetadata.name -ne $mibs.name) {
    throw 'MIB artifact identity mismatch'
}
Invoke-WebRequest "$mibsApi/actions/artifacts/$($mibs.artifactId)/zip" -Headers $headers -OutFile artifacts/net-snmp.zip
if ((Get-FileHash artifacts/net-snmp.zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $mibs.sha256) {
    throw 'MIB artifact hash mismatch'
}
Expand-Archive artifacts/net-snmp.zip artifacts/net-snmp
$env:MIBDIRS = (Resolve-Path artifacts/net-snmp/share/mibs).Path


function Invoke-CheckedPhp {
    param([string] $Executable, [string[]] $Arguments)
    $stderrFile = Join-Path (Resolve-Path reports).Path 'php-stderr.txt'
    $output = & $Executable @Arguments 2> $stderrFile
    $status = $LASTEXITCODE
    Get-Content $stderrFile | ForEach-Object { Write-Host $_ }
    $output | ForEach-Object { Write-Host $_ }
    if ($status -ne 0) { throw "PHP exited with $status" }
    return ($output -join "`n")
}

# Exercise the packaged Net-SNMP agent against each exact PHP artifact.
# The only account is a disposable loopback test fixture; credentials live in the test.
$agentRuntime = @($row.runtimeZips | Where-Object arch -EQ 'x64')[0]
$agentZip = Join-Path artifacts/runtime $agentRuntime.name
if ((Get-FileHash $agentZip).Hash.ToLowerInvariant() -ne $agentRuntime.sha256) { throw 'Agent runtime digest mismatch' }
Expand-Archive $agentZip artifacts/agent-runtime
Get-ChildItem artifacts/agent-runtime -Filter 'libcrypto-*.dll' | Copy-Item -Destination artifacts/net-snmp/bin
Get-ChildItem artifacts/agent-runtime -Filter 'libssl-*.dll' | Copy-Item -Destination artifacts/net-snmp/bin
New-Item artifacts/agent-config, artifacts/agent-state -ItemType Directory -Force | Out-Null
$env:SNMPCONFPATH = (Resolve-Path artifacts/agent-config).Path
$env:SNMP_PERSISTENT_DIR = (Resolve-Path artifacts/agent-state).Path
# An explicit SNMPCONFPATH replaces the default search, including persistence.
# Include both directories so the agent reads the createUser fixture.
$env:SNMPCONFPATH += ";$env:SNMP_PERSISTENT_DIR"
$env:OPENSSL_CONF = (Resolve-Path artifacts/agent-runtime/extras/ssl/openssl.cnf).Path
$port = Get-Random -Minimum 20000 -Maximum 60000
@("agentaddress udp:127.0.0.1:$port", 'rocommunity release-community 127.0.0.1', 'rouser releaseqa priv', 'sysDescr Winlibs OpenSSL release validation') | Set-Content artifacts/agent-config/snmpd.conf
'createUser releaseqa SHA ReleaseAuthOnlyForTests AES ReleasePrivacyOnlyForTests' | Set-Content artifacts/agent-state/snmpd.conf
$agent = Start-Process (Resolve-Path artifacts/net-snmp/bin/snmpd.exe).Path -ArgumentList '-f','-Lo' -PassThru -NoNewWindow -RedirectStandardOutput reports/snmpd.log -RedirectStandardError reports/snmpd-stderr.log
$ready = $false
for ($attempt=0; $attempt -lt 60; $attempt++) {
    if ($agent.HasExited) { Get-Content reports/snmpd.log, reports/snmpd-stderr.log; throw "SNMP agent exited with $($agent.ExitCode)" }
    if (Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue) { $ready=$true; break }
    Start-Sleep -Milliseconds 500
}
if (!$ready) { Stop-Process -Id $agent.Id -Force; throw 'SNMP agent did not bind loopback' }
@{package=$mibs; executableSha256=(Get-FileHash artifacts/net-snmp/bin/snmpd.exe).Hash.ToLowerInvariant(); endpoint="127.0.0.1:$port"} | ConvertTo-Json -Depth 10 | Set-Content reports/snmp-agent.json
$results = @()
foreach ($runtime in $row.runtimeZips) {
    $result = [ordered]@{
        php = $Php
        runId = $row.runId
        artifactId = $row.artifactId
        archiveSha256 = $actualArchiveHash
        runtime = $runtime.name
        arch = $runtime.arch
        ts = $runtime.ts
        passed = $false
    }
    Write-Host "::group::$($runtime.name)"
    try {
        $zip = Join-Path artifacts/runtime $runtime.name
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $runtime.sha256) { throw "Runtime ZIP hash mismatch: $zip" }
        $result.runtimeSha256 = $hash
        $destination = Join-Path (Resolve-Path php-builds).Path "$($runtime.arch)-$($runtime.ts)"
        Expand-Archive $zip $destination
        $exe = Join-Path $destination php.exe
        $ext = Join-Path $destination ext
        $env:OPENSSL_CONF = Join-Path $destination extras/ssl/openssl.cnf
        if (!(Test-Path $env:OPENSSL_CONF)) { throw 'Packaged OpenSSL configuration is missing' }

        $dllHashes = @{}
        foreach ($property in $runtime.dllHashes.PSObject.Properties) {
            $dll = Join-Path $destination $property.Name
            $actual = (Get-FileHash $dll -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $property.Value) { throw "DLL hash mismatch: $($property.Name)" }
            $dllHashes[$property.Name] = $actual
        }
        if ($dllHashes.Count -lt 2) { throw 'Missing pinned OpenSSL DLL identities' }
        $result.dllHashes = $dllHashes

        $base = @('-n', '-d', "extension_dir=$ext", '-d', 'extension=openssl')
        $identity = Invoke-CheckedPhp $exe ($base + @('-r', 'echo json_encode(["version"=>PHP_VERSION,"bits"=>PHP_INT_SIZE*8,"zts"=>(bool)PHP_ZTS]);'))
        $identity = $identity | ConvertFrom-Json
        $expectedBits = if ($runtime.arch -eq 'x64') { 64 } else { 32 }
        if ($identity.bits -ne $expectedBits -or $identity.zts -ne ($runtime.ts -eq 'ts')) { throw 'PHP runtime architecture/TS mismatch' }
        if ($identity.version -ne $runtime.phpVersion) { throw 'PHP source version mismatch' }
        $result.phpVersion = $identity.version

        $info = Invoke-CheckedPhp $exe ($base + @('--ri', 'openssl'))
        $expected = [regex]::Escape($row.opensslVersion)
        if ($info -notmatch "(?m)^OpenSSL Library Version\s*=>\s*OpenSSL $expected(?:\s|$)") {
            throw "Loaded OpenSSL runtime is not $($row.opensslVersion)"
        }
        Invoke-CheckedPhp $exe ($base + @('-d', 'error_reporting=-1', 'tests/openssl-artifact-smoke.php', '--allow-non-openssl4')) | Out-Null

        $modules = $base + @('-d', 'extension=curl', '-d', 'extension=ldap', '-d', 'extension=pgsql', '-d', 'extension=pdo_pgsql', '-d', 'extension=snmp')
        $consumers = Invoke-CheckedPhp $exe ($modules + @('tests/consumer-extensions.php'))
        $result.consumers = $consumers | ConvertFrom-Json
        if ($result.consumers.curl_ssl -notmatch "^OpenSSL/$expected(?:\s|$)") { throw 'curl loaded an unexpected OpenSSL runtime' }
        $snmp = Invoke-CheckedPhp $exe ($base + @('-d', 'extension=snmp', 'tests/snmp-roundtrip.php', "127.0.0.1:$port"))
        $result.snmp = $snmp | ConvertFrom-Json
        $result.passed = $true
    } catch {
        $result.error = $_.ToString()
        Write-Host "::error::$($runtime.name): $_"
    } finally {
        $results += [pscustomobject]$result
        $results | ConvertTo-Json -Depth 20 | Set-Content reports/results.json
        Write-Host '::endgroup::'
    }
}
Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue
Stop-Transcript
if ($results.Count -ne 4 -or @($results | Where-Object passed -NE $true).Count -gt 0) {
    throw 'One or more PHP artifact variants failed validation'
}
