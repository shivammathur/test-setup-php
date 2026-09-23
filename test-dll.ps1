param([string]$BinPath)
$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 4) { throw 'DLL validation requires an x86 process' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeArchive {
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr LoadLibrary(string name);
    [DllImport("kernel32", CharSet=CharSet.Ansi, ExactSpelling=true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32")]
    public static extern bool FreeLibrary(IntPtr module);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    public delegate int GetCount(out uint count);
}
'@
foreach ($name in @('7za.dll', '7zxa.dll')) {
    $module = [NativeArchive]::LoadLibrary((Join-Path $BinPath $name))
    if ($module -eq [IntPtr]::Zero) { throw "LoadLibrary failed: $name" }
    try {
        foreach ($symbol in @('GetNumberOfFormats','GetNumberOfMethods')) {
            $address = [NativeArchive]::GetProcAddress($module, $symbol)
            if ($address -eq [IntPtr]::Zero) { throw "Missing export: $symbol" }
            $fn = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($address, [NativeArchive+GetCount])
            [uint32]$count = 0
            if ($fn.Invoke([ref]$count) -ne 0 -or $count -eq 0) { throw "Invalid result: $name $symbol" }
            Write-Output "$name $symbol = $count"
        }
    } finally { [void][NativeArchive]::FreeLibrary($module) }
}
