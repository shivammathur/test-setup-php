param(
    [ValidateSet('Cpu', 'Process')]
    [string] $Mode = 'Cpu',
    [int] $Seconds = 300
)

$ErrorActionPreference = 'SilentlyContinue'
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)

if ($Mode -eq 'Process') {
    while ([DateTime]::UtcNow -lt $deadline) {
        $process = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" `
                                 -ArgumentList '/d', '/c', 'exit', '0' `
                                 -WindowStyle Hidden `
                                 -PassThru
        $process.WaitForExit()
        $process.Dispose()
    }
    exit 0
}

$value = 0.123456789
while ([DateTime]::UtcNow -lt $deadline) {
    for ($i = 0; $i -lt 200000; $i++) {
        $value = [Math]::Sqrt(($value * 1.0000001) + 3.1415926535)
    }
}

Write-Output $value

