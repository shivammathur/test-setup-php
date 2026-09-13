param(
    [Parameter(Mandatory)][string]$ProductDirectory,
    [Parameter(Mandatory)][string]$PhpTarget,
    [Parameter(Mandatory)][string]$PackagePhpTarget,
    [Parameter(Mandatory)][string]$Arch,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$PackageOpenSsl,
    [Parameter(Mandatory)][string]$RuntimeOpenSsl,
    [Parameter(Mandatory)][string]$ProductArchive,
    [Parameter(Mandatory)][string]$OpenSslArchive,
    [Parameter(Mandatory)][string]$OpenSslDirectory,
    [Parameter(Mandatory)][string]$ReportsDirectory
)

$ErrorActionPreference = 'Stop'
New-Item -Path $ReportsDirectory -ItemType Directory -Force | Out-Null
$contextPath = Join-Path $ReportsDirectory 'context.json'
[ordered]@{
    php = $PhpTarget
    packagePhp = $PackagePhpTarget
    arch = $Arch
    builderRun = $RunId
    runner = $env:ImageOS
} | ConvertTo-Json | Set-Content -LiteralPath $contextPath

$exe = Join-Path $ProductDirectory 'bin\snmpd.exe'
$library = Join-Path $ProductDirectory 'lib\netsnmp.lib'
$configHeader = Join-Path $ProductDirectory 'include\net-snmp\net-snmp-config.h'
$cdxPath = Join-Path $ProductDirectory 'share\sbom\net-snmp.cdx.json'
$vexPath = Join-Path $ProductDirectory 'share\sbom\net-snmp.openvex.json'
$openSslCdxPath = Join-Path $OpenSslDirectory 'share\sbom\openssl.cdx.json'
foreach ($path in @($exe, $library, $configHeader, $cdxPath, $vexPath, $openSslCdxPath, $ProductArchive, $OpenSslArchive)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing expected artifact file: $path"
    }
}

$openSslBin = Join-Path $OpenSslDirectory 'bin'
$openSslDlls = @(
    Get-ChildItem -LiteralPath $openSslBin -File |
        Where-Object { $_.Name -match '^lib(?:crypto|ssl)-3(?:-x64)?\.dll$' }
)
if ($openSslDlls.Count -ne 2) {
    throw "Expected the exact OpenSSL runtime DLL pair, found $($openSslDlls.Count)."
}

if (Get-ChildItem -LiteralPath $ProductDirectory -Recurse -File -Filter '*snmptrapd*') {
    throw 'snmptrapd unexpectedly appears in the Winlibs package.'
}

$cdx = Get-Content -LiteralPath $cdxPath -Raw | ConvertFrom-Json -Depth 100
$vex = Get-Content -LiteralPath $vexPath -Raw | ConvertFrom-Json -Depth 100
$component = $cdx.metadata.component
$properties = @{}
foreach ($property in @($component.properties)) { $properties[$property.name] = $property.value }

if ($component.version -ne '5.9.4-2' -or $component.purl -ne 'pkg:generic/net-snmp@5.9.4') {
    throw 'Unexpected Net-SNMP component identity.'
}
if ($properties['php:source-ref'] -ne 'net-snmp-5.9.4-2' -or
    $properties['php:source-commit'] -ne '7662537b29b1e278c65ab786ac4641cd6fb5b9d4' -or
    $properties['php:php-version'] -ne $PackagePhpTarget -or
    $properties['php:arch'] -ne $Arch) {
    throw 'Artifact provenance does not match the requested source, PHP target, or architecture.'
}

$openssl = @($cdx.components | Where-Object { $_.name -eq 'openssl' -and $_.version -eq $PackageOpenSsl })
if ($openssl.Count -ne 1) { throw "Expected build-time OpenSSL $PackageOpenSsl dependency was not recorded." }
$runtimeOpenSslCdx = Get-Content -LiteralPath $openSslCdxPath -Raw | ConvertFrom-Json -Depth 100
if ($runtimeOpenSslCdx.metadata.component.name -ne 'openssl' -or
    $runtimeOpenSslCdx.metadata.component.version -ne $RuntimeOpenSsl) {
    throw "Published runtime OpenSSL does not match $RuntimeOpenSsl."
}

$finding = @($cdx.vulnerabilities | Where-Object {
    $_.id -eq 'CVE-2026-89147' -and $_.analysis.state -eq 'resolved_with_pedigree'
})
$statement = @($vex.statements | Where-Object {
    $_.vulnerability.name -eq 'CVE-2026-89147' -and $_.status -eq 'fixed'
})
if ($finding.Count -ne 1 -or $statement.Count -ne 1) {
    throw 'The CVE-2026-89147 CycloneDX/OpenVEX disposition is missing.'
}

$configText = Get-Content -LiteralPath $configHeader -Raw
if ($configText -notmatch '(?m)^/\* #undef USING_SMUX_MODULE \*/\s*$') {
    throw 'The shipped Windows configuration unexpectedly enables the SMUX module.'
}

$headers = (& dumpbin /nologo /headers $exe) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect snmpd.exe.' }
$machinePattern = if ($Arch -eq 'x64') { '8664 machine \(x64\)' } else { '14C machine \(x86\)' }
if ($headers -notmatch $machinePattern) { throw "snmpd.exe does not match $Arch." }
foreach ($dll in $openSslDlls) {
    $dependencyHeaders = (& dumpbin /nologo /headers $dll.FullName) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $dependencyHeaders -notmatch $machinePattern) {
        throw "$($dll.Name) does not match $Arch."
    }
}

$symbols = (& dumpbin /nologo /linkermember:1 $library) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect netsnmp.lib.' }
if ($symbols -match '(?m)\b_?smux_accept(?:@\d+)?\s*$') {
    throw 'The vulnerable SMUX agent entry point is present in the packaged PHP library.'
}

function Test-TcpPort {
    param([int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait(750)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Invoke-SnmpProbe {
    param([int]$Timeout = 750)
    [byte[]]$request = 0x30,0x28,0x02,0x01,0x01,0x04,0x06,0x70,0x75,0x62,0x6c,0x69,0x63,0xa0,0x1b,0x02,0x04,0x12,0x34,0x56,0x78,0x02,0x01,0x00,0x02,0x01,0x00,0x30,0x0d,0x30,0x0b,0x06,0x07,0x2b,0x06,0x01,0x02,0x01,0x01,0x03,0x05,0x00
    $udp = [Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $Timeout
        [void]$udp.Send($request, $request.Length, '127.0.0.1', 31161)
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$remote)
        return $response.Length -gt 0
    } catch {
        return $false
    } finally {
        $udp.Dispose()
    }
}

if (Test-TcpPort -Port 199) { throw 'TCP port 199 is already in use on the runner.' }
$work = Join-Path $env:RUNNER_TEMP ([guid]::NewGuid().ToString())
New-Item -Path $work -ItemType Directory | Out-Null
$config = Join-Path $work 'snmpd.conf'
$stdout = Join-Path $work 'snmpd.stdout.log'
$stderr = Join-Path $work 'snmpd.stderr.log'
$persistent = Join-Path $work 'persistent'
New-Item -Path $persistent -ItemType Directory | Out-Null
Set-Content -LiteralPath $config -Value @('agentaddress udp:127.0.0.1:31161', 'rocommunity public 127.0.0.1')
$env:MIBDIRS = Join-Path $ProductDirectory 'share\mibs'
$env:MIBS = ''
$env:SNMP_PERSISTENT_DIR = $persistent
$env:PATH = "$(Resolve-Path -LiteralPath $openSslBin);$env:PATH"
$process = Start-Process -FilePath $exe -ArgumentList @(
    '-f', '-C', '-c', $config, '-Le', '-Dread_config,transport,snmp_agent,smux'
) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 30 -and -not $ready; $attempt++) {
        if ($process.HasExited) { throw "snmpd.exe exited early with code $($process.ExitCode)." }
        $ready = Invoke-SnmpProbe
        if (-not $ready) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) {
        $udpListener = @(Get-NetUDPEndpoint -LocalPort 31161 -ErrorAction SilentlyContinue).Count -gt 0
        throw "snmpd.exe did not answer a local SNMP probe (UDP listener present: $udpListener)."
    }
    if (Test-TcpPort -Port 199) { throw 'The disabled SMUX listener is reachable in the shipped executable.' }
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    foreach ($entry in @(
        @{ Source = $config; Name = 'snmpd.conf' },
        @{ Source = $stdout; Name = 'snmpd.stdout.log' },
        @{ Source = $stderr; Name = 'snmpd.stderr.log' }
    )) {
        if (Test-Path -LiteralPath $entry.Source) {
            Copy-Item -LiteralPath $entry.Source -Destination (Join-Path $ReportsDirectory $entry.Name) -Force
        }
    }
}

$result = [ordered]@{
    passed = $true
    php = $PhpTarget
    arch = $Arch
    builderRun = $RunId
    sourceCommit = $properties['php:source-commit']
    packagePhp = $PackagePhpTarget
    packageOpenSsl = $PackageOpenSsl
    runtimeOpenSsl = $RuntimeOpenSsl
    productArchiveSha256 = (Get-FileHash -LiteralPath $ProductArchive -Algorithm SHA256).Hash
    openSslArchiveSha256 = (Get-FileHash -LiteralPath $OpenSslArchive -Algorithm SHA256).Hash
    smuxRuntime = 'not-linked'
    cve = $finding[0].analysis.state
    vex = $statement[0].status
    files = @(
        Get-Item -LiteralPath $exe, $library, $cdxPath, $vexPath |
            ForEach-Object { [ordered]@{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } }
    )
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ReportsDirectory 'native.json')
Write-Host "PASS: Net-SNMP $PhpTarget $Arch source, VEX, architecture, runtime, and SMUX exclusion"
