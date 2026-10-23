$ErrorActionPreference = 'Stop'
$root = "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers"
if (!(Test-Path "$root\x86\cdb.exe") -or !(Test-Path "$root\x64\cdb.exe")) {
    $installer = Join-Path $env:RUNNER_TEMP 'winsdksetup.exe'
    Invoke-WebRequest 'https://go.microsoft.com/fwlink/?linkid=2243390' -OutFile $installer
    $process = Start-Process $installer -ArgumentList '/features OptionId.WindowsDesktopDebuggers /quiet /norestart /ceip off' -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "SDK installation exit $($process.ExitCode)" }
}
foreach ($arch in @('x86', 'x64')) {
    if (!(Test-Path "$root\$arch\cdb.exe")) { throw "Missing $arch cdb" }
}
"CDB_ROOT=$root" >> $env:GITHUB_ENV
