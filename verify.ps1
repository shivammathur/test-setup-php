$ErrorActionPreference = 'Stop'
$root = 'C:\pr24246'
$allowed = "$root\allowed"
$share = 'Php24246'
$nulPayload = 'regular-nul-file-24246'
$ordinaryPayload = 'ordinary-file-24246'
New-Item -ItemType Directory -Force reports | Out-Null
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber |
    ConvertTo-Json | Set-Content reports/windows.json

# These controls use handles, not PHP's path normalization or device-name checks.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class NativeFixture {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetFileType(SafeFileHandle handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    public static extern bool DeleteFileW(string path);
    private static FileStream Open(string path, bool write) {
        SafeFileHandle h = CreateFileW(path, write ? 0x40000000u : 0x80000000u,
            7, IntPtr.Zero, write ? 2u : 3u, 0x80, IntPtr.Zero);
        if (h.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new Win32Exception(error, path + ": " + new Win32Exception(error).Message);
        }
        if (GetFileType(h) != 1) { h.Dispose(); throw new IOException("Not a disk file: " + path); }
        return new FileStream(h, write ? FileAccess.Write : FileAccess.Read);
    }
    public static void Write(string path, string text) {
        using (FileStream f = Open(path, true)) {
            byte[] bytes = Encoding.ASCII.GetBytes(text);
            f.Write(bytes, 0, bytes.Length);
        }
    }
    public static string Read(string path) {
        using (FileStream f = Open(path, false))
        using (StreamReader r = new StreamReader(f, Encoding.ASCII)) { return r.ReadToEnd(); }
    }
}
'@

$shas = @{
    parent = 'd5a94412e3635fd6537a922603b096b0d0c121eb'
    pr = 'a360b048ca4e4e84c97a0444580549fd7ca33518'
}
$executables = @{}
$manifests = @{}
foreach ($variant in @('parent', 'pr')) {
    $dir = "$PWD\binaries\php-$variant-$env:PHPTS"
    $manifest = Get-Content "$dir/provenance.json" -Raw | ConvertFrom-Json
    if ($manifest.sha -ne $shas[$variant] -or $manifest.ts -ne $env:PHPTS) { throw 'Incorrect build provenance' }
    foreach ($file in $manifest.files) {
        if ((Get-FileHash "$dir/$($file.name)" -Algorithm SHA256).Hash -ne $file.sha256) { throw "Hash mismatch: $($file.name)" }
    }
    Copy-Item "$dir/provenance.json" "reports/$variant-provenance.json"
    $executables[$variant] = "$dir/php.exe"
    $manifests[$variant] = $manifest
}
foreach ($file in $manifests.parent.files) {
    if ($file.name -match '^php(?:\.exe|8(?:ts)?\.dll)$') { continue }
    $other = $manifests.pr.files | Where-Object name -EQ $file.name
    if ($other.sha256 -ne $file.sha256) { throw "A/B dependency mismatch: $($file.name)" }
}

if (Test-Path $root) { throw "Fixture already exists: $root" }
New-Item -ItemType Directory $allowed, "$root\outside" | Out-Null
$shareCreated = $false
try {
    [NativeFixture]::Write("\\?\$allowed\NUL", $nulPayload)
    [NativeFixture]::Write("\\?\$allowed\ok.txt", $ordinaryPayload)
    [NativeFixture]::Write("\\?\$root\outside\ok.txt", $ordinaryPayload)
    Start-Service LanmanServer
    New-SmbShare -Name $share -Path $allowed -FullAccess ([Security.Principal.WindowsIdentity]::GetCurrent().Name) | Out-Null
    $shareCreated = $true
    if ([NativeFixture]::Read("\\.\$allowed\NUL") -cne $nulPayload) { throw 'Local NUL fixture invalid' }
    Get-SmbShareAccess -Name $share | Select-Object AccountName, AccessControlType, AccessRight |
        ConvertTo-Json | Set-Content reports/share-access.json
    $native = @()
    foreach ($server in @('localhost', $env:COMPUTERNAME, '127.0.0.1')) {
        foreach ($prefix in @('\\.\UNC\', '\\?\UNC\', '\\')) {
            foreach ($name in @('ok.txt', 'NUL')) {
                $path = "$prefix$server\$share\$name"
                $record = [ordered]@{ path = $path; server = $server; prefix = $prefix; name = $name; content = $null; error = $null; code = $null }
                try { $record.content = [NativeFixture]::Read($path) }
                catch {
                    $nativeError = $_.Exception.GetBaseException()
                    $record.error = $nativeError.Message
                    $record.code = $nativeError.NativeErrorCode
                }
                $native += [pscustomobject]$record
            }
        }
    }
    $native | ConvertTo-Json -Depth 4 | Set-Content reports/native-controls.json
    $native | Format-Table path, content, code -AutoSize
    $working = $native | Where-Object { $_.prefix -eq '\\.\UNC\' -and $_.name -eq 'ok.txt' -and $_.content -ceq $ordinaryPayload } | Select-Object -First 1
    $server = if ($working) { $working.server } else { 'localhost' }

    $cases = @(
        @{ id = 'local-ordinary'; path = "\\.\$allowed\ok.txt"; mode = 'none'; payload = $ordinaryPayload },
        @{ id = 'local-nul'; path = "\\.\$allowed\NUL"; mode = 'none'; payload = $nulPayload },
        @{ id = 'unc-ordinary'; path = "\\.\UNC\$server\$share\ok.txt"; mode = 'none'; payload = $ordinaryPayload },
        @{ id = 'unc-nul'; path = "\\.\UNC\$server\$share\NUL"; mode = 'none'; payload = $nulPayload; regression = $true },
        @{ id = 'plain-nul-denied'; path = "$allowed\NUL"; mode = 'none'; denied = $true }
    )
    foreach ($mode in @('startup', 'runtime')) {
        $cases += @(
            @{ id = "basedir-ordinary-$mode"; path = "\\.\$allowed\ok.txt"; mode = $mode; payload = $ordinaryPayload },
            @{ id = "basedir-nul-$mode"; path = "\\.\$allowed\NUL"; mode = $mode; payload = $nulPayload; regression = $true },
            @{ id = "basedir-outside-denied-$mode"; path = "\\.\$root\outside\ok.txt"; mode = $mode; denied = $true }
        )
    }
    $code = (Get-Content probe.php -Raw) -replace '^<\?php\s*', ''
    $summary = @()
    $failures = @()
    foreach ($case in $cases) {
        $observations = @{}
        foreach ($variant in @('parent', 'pr')) {
            $arguments = @('-n', '-d', 'display_errors=stderr')
            # Single-quoted INI values preserve the two leading backslashes.
            if ($case.mode -eq 'startup') { $arguments += @('-d', "open_basedir='\\.\$allowed'") }
            $arguments += @('-r', $code, '--', $case.path, $case.mode, "\\.\$allowed")
            $output = & $executables[$variant] @arguments
            if ($LASTEXITCODE) { throw "$variant / $($case.id) exited with $LASTEXITCODE" }
            $output | Set-Content "reports/$variant-$($case.id).json"
            $result = $output | ConvertFrom-Json
            $expectedZts = if ($env:PHPTS -eq 'ts') { 1 } else { 0 }
            if ($result.zts -ne $expectedZts -or $result.bits -ne 64) { throw 'Incorrect PHP runtime' }
            if ($case.mode -ne 'none' -and !$result.open_basedir) { throw 'open_basedir was not enabled' }
            if ($case.mode -eq 'startup' -and $result.open_basedir -cne "\\.\$allowed") { throw 'Startup INI path changed spelling' }
            if ($case.mode -eq 'runtime' -and $result.setting.value -ceq $false) { throw 'ini_set failed' }
            $readOk = $result.read.value -is [string] -and $result.read.value -ceq $case.payload
            $observations[$variant] = $readOk
            if ($case.denied) {
                if ($result.read.value -cne $false) { $failures += "Negative control failed: $variant / $($case.id)" }
            } elseif (!$case.regression -and !$readOk) {
                $failures += "Positive control failed: $variant / $($case.id)"
            }
        }
        $verdict = 'control passed'
        if ($case.regression) {
            $verdict = if (!$observations.parent) { 'not confirmed: parent also fails' }
                elseif ($observations.pr) { 'not reproduced' } else { 'regression confirmed' }
        } elseif ($failures -match [regex]::Escape($case.id)) {
            $verdict = 'control failed'
        }
        $summary += [pscustomobject]@{ case = $case.id; parentRead = $observations.parent; prRead = $observations.pr; verdict = $verdict }
    }
    $summary | ConvertTo-Json | Set-Content reports/summary.json
    $table = @('| Case | Parent reads marker | PR reads marker | Verdict |', '| --- | --- | --- | --- |')
    $table += $summary | ForEach-Object { "| $($_.case) | $($_.parentRead) | $($_.prRead) | $($_.verdict) |" }
    $table | Set-Content reports/summary.md
    $table | Add-Content $env:GITHUB_STEP_SUMMARY
    $summary | Format-Table -AutoSize
    if ($failures.Count) { throw ($failures -join "`n") }
} finally {
    if ($shareCreated) { Remove-SmbShare -Name $share -Force }
    if (![NativeFixture]::DeleteFileW("\\?\$allowed\NUL")) { Write-Warning 'NUL fixture cleanup failed' }
    Remove-Item $root -Recurse -Force
}
