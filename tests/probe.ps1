param([ValidateSet('ts', 'nts')][string]$ExpectedTs)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class DeviceFileProbe
{
    [DllImport("ntdll.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern uint RtlIsDosDeviceName_U(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint GetFileType(SafeFileHandle handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle handle, byte[] data, uint length, out uint written, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle handle, byte[] data, uint length, out uint read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle handle, long distance, out long position, uint method);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StreamData
    {
        public long Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)] public string Name;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstStreamW(string path, int level, out StreamData data, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool FindNextStreamW(IntPtr handle, out StreamData data);
    [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr handle);

    public static string[] Streams(string path)
    {
        var names = new List<string>();
        StreamData data;
        IntPtr handle = FindFirstStreamW(path, 0, out data, 0);
        if (handle == new IntPtr(-1)) return names.ToArray();
        try { do { names.Add(data.Name); } while (FindNextStreamW(handle, out data)); }
        finally { FindClose(handle); }
        return names.ToArray();
    }

    static string Read(SafeFileHandle handle, int size)
    {
        byte[] bytes = new byte[size];
        uint read;
        if (!ReadFile(handle, bytes, (uint)size, out read, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return Encoding.ASCII.GetString(bytes, 0, (int)read);
    }

    public static Dictionary<string, object> Probe(string path, string marker)
    {
        var row = new Dictionary<string, object> {
            { "path", path }, { "rtl_path", RtlIsDosDeviceName_U(path) }, { "kind", "failed" }
        };
        using (var handle = CreateFileW(path, 0xC0000000, 7, IntPtr.Zero, 2, 0x80, IntPtr.Zero))
        {
            if (handle.IsInvalid) {
                row["error"] = Marshal.GetLastWin32Error();
                return row;
            }
            uint type = GetFileType(handle);
            row["file_type"] = type;
            row["kind"] = type == 1 ? "disk" : type == 2 ? "character" : "unknown";
            byte[] bytes = Encoding.ASCII.GetBytes(marker);
            uint written;
            if (!WriteFile(handle, bytes, (uint)bytes.Length, out written, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            row["written"] = written;
            if (type != 1) return row;
            long position;
            if (!SetFilePointerEx(handle, 0, out position, 0))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            row["read_back"] = Read(handle, bytes.Length);
        }
        using (var reopened = CreateFileW(path, 0x80000000, 7, IntPtr.Zero, 3, 0x80, IntPtr.Zero))
        {
            if (reopened.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            row["persisted"] = Read(reopened, marker.Length);
        }
        return row;
    }
}
'@

$root = Join-Path $env:RUNNER_TEMP ('device-filenames-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
[void][IO.Directory]::CreateDirectory('results')
$names = @('regular.txt', 'NUL', 'NUL.txt', 'NUL .txt', 'NUL :txt')
$names | ConvertTo-Json | Set-Content (Join-Path $root 'cases.json')
$marker = 'native-persisted-content'
$native = @()
foreach ($namespace in @('normal', 'extended', 'device')) {
    for ($i = 0; $i -lt $names.Count; $i++) {
        $dir = [IO.Path]::GetFullPath((Join-Path $root "native/$namespace/$i"))
        [void][IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir $names[$i]
        if ($namespace -eq 'extended') { $path = '\\?\' + $path }
        if ($namespace -eq 'device') { $path = '\\.\' + $path }
        $row = [DeviceFileProbe]::Probe($path, $marker)
        $row['name'] = $names[$i]
        $row['namespace'] = $namespace
        $row['rtl_name'] = [DeviceFileProbe]::RtlIsDosDeviceName_U($names[$i])
        $row['entries'] = @([IO.Directory]::GetFileSystemEntries($dir) | ForEach-Object {
            @{ name = [IO.Path]::GetFileName($_); streams = @([DeviceFileProbe]::Streams('\\?\' + $_)) }
        })
        $native += $row
    }
}

$phpOutput = & php -n "$PSScriptRoot/probe.php" (Join-Path $root 'php') (Join-Path $root 'cases.json')
if ($LASTEXITCODE -ne 0) { throw 'PHP probe failed' }
$php = $phpOutput | ConvertFrom-Json -AsHashtable
foreach ($row in $php.rows) {
    $dir = [IO.Path]::GetDirectoryName($row.path)
    $row['streams'] = @([IO.Directory]::GetFileSystemEntries($dir) | ForEach-Object {
        @{ name = [IO.Path]::GetFileName($_); streams = @([DeviceFileProbe]::Streams('\\?\' + $_)) }
    })
}

$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$report = @{
    os = @{ product = $os.ProductName; build = $os.CurrentBuildNumber; ubr = $os.UBR; display_version = $os.DisplayVersion }
    runner_image = $env:ImageVersion
    native_marker = $marker
    native = $native
    php = $php
}
$report | ConvertTo-Json -Depth 15 | Set-Content results/observations.json
$summary = @(
    "OS: $($os.ProductName), build $($os.CurrentBuildNumber).$($os.UBR)"
    "PHP: $($php.version), ZTS=$($php.zts), integer bytes=$($php.int_size)"
    ''
    '| API | Namespace | Name | Rtl(name) | Kind | Directory entries |'
    '| --- | --- | --- | --- | --- | --- |'
)
foreach ($row in $native) {
    if ($row.kind -eq 'unknown') { throw "Unknown native handle type: $($row.path)" }
    $entries = @($row.entries | ForEach-Object { $_.name }) -join ', '
    $summary += '| Win32 | ' + $row.namespace + ' | `' + $row.name + '` | ' + $row.rtl_name + ' | ' + $row.kind + ' | `' + $entries + '` |'
}
foreach ($row in $php.rows) {
    if ($row.kind -eq 'unknown') { throw "Unknown PHP handle type: $($row.path)" }
    $summary += '| PHP | normal | `' + $row.name + '` | | ' + $row.kind + ' | `' + ($row.entries -join ', ') + '` |'
}
$summary | Set-Content results/summary.md
$summary | Write-Output
$summary | Add-Content $env:GITHUB_STEP_SUMMARY

if ($php.zts -ne [int]($ExpectedTs -eq 'ts') -or $php.int_size -ne 8 -or !$php.version.StartsWith('8.2.')) {
    throw 'Unexpected PHP build'
}
foreach ($row in $native) {
    if ($row.name -eq 'regular.txt' -and $row.kind -ne 'disk') { throw 'Native control failed' }
    if ($row.kind -eq 'disk' -and ($row.read_back -ne $marker -or $row.persisted -ne $marker -or $row.entries.Count -eq 0)) {
        throw "Native persistence check failed: $($row.path)"
    }
}
foreach ($row in $php.rows) {
    if ($row.name -eq 'regular.txt' -and $row.kind -ne 'disk') { throw 'PHP control failed' }
    if ($row.kind -eq 'disk' -and ($row.read_back -ne $php.marker -or $row.persisted -ne $php.marker -or $row.entries.Count -eq 0)) {
        throw "PHP persistence check failed: $($row.path)"
    }
}
Write-Output 'PASS: PHP build identity, ordinary-file controls, and all observed disk-file persistence checks'
