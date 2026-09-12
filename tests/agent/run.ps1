param([Parameter(Mandatory)][string]$Arch)
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$report = New-Item reports -ItemType Directory -Force
$include = @('net-snmp/win32','net-snmp/include','net-snmp/agent','net-snmp/agent/mibgroup','net-snmp','deps/include') | ForEach-Object { "/I$root/$_" }
$libs = @('netsnmpagent.lib','netsnmpmibs.lib',"$root/native/lib/netsnmp.lib",'advapi32.lib','ws2_32.lib','kernel32.lib','user32.lib') + @(Get-ChildItem deps/lib/*.lib | ForEach-Object FullName)
$results = @()
foreach ($kind in @('logging','vacm')) {
    $file = if ($kind -eq 'logging') { 'agent/mibgroup/agent/nsLogging.c' } else { 'agent/mibgroup/mibII/vacm_vars.c' }
    foreach ($variant in @('fixed','old')) {
        if ($variant -eq 'old') {
            $content = & git -C net-snmp show "2ef6429c7f820a25ddd653e8ee6ecd53f9208067:$file"
            if ($LASTEXITCODE -ne 0) { throw 'Unable to retrieve negative-control source' }
            [IO.File]::WriteAllText("$root/net-snmp/$file", ($content -join "`n") + "`n")
        }
        $exe = "$root/reports/$kind-$variant.exe"
        & cl /nologo /MD /O2 /DWIN32 /DNDEBUG /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS @include "tests/agent/$kind.c" "/Fe:$exe" /link "/LIBPATH:$root/net-snmp/win32/lib/release" @libs
        if ($LASTEXITCODE -ne 0) { throw "Harness compile failed: $kind/$variant" }
        $output = & $exe 2>&1
        $code = $LASTEXITCODE
        $expected = if ($variant -eq 'fixed') { 0 } else { -1073741819 }
        if ($code -ne $expected) { throw "Unexpected result for $kind/$variant : $code expected $expected : $output" }
        $results += @{ case = "$kind/$variant"; exitCode = $code; expected = $expected; output = @($output | ForEach-Object { "$_" }); passed = $true }
        & git -C net-snmp restore $file
        if ($LASTEXITCODE -ne 0) { throw 'Unable to restore fixed source' }
    }
}
$binary = Get-Item native/bin/snmpd.exe
$output = & $binary.FullName -v 2>&1
if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch '5\.7\.3') { throw "Packaged snmpd version check failed: $output" }
$hashes = Get-ChildItem native -Recurse -File | Where-Object { $_.Extension -in @('.lib','.exe') } | ForEach-Object { @{ file = $_.FullName.Substring($root.Length+1); sha256 = (Get-FileHash $_.FullName).Hash } }
@{ arch = $Arch; cases = $results; binaries = @($hashes); packagedSnmpd = @($output | ForEach-Object { "$_" }) } | ConvertTo-Json -Depth 10 | Set-Content reports/agent-regressions.json
