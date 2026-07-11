param(
    [int] $Iterations = 30,
    [Parameter(Mandatory = $true)]
    [string] $Scenario,
    [Parameter(Mandatory = $true)]
    [string] $OutputPath
)

$ErrorActionPreference = 'Continue'
$results = [System.Collections.Generic.List[object]]::new()

for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    foreach ($phase in @('skipif', 'file')) {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $instance = $null
        $success = $false
        $hresult = $null
        $message = $null
        try {
            $instance = New-Object -ComObject InternetExplorer.Application
            $instance.Quit()
            $success = $true
        } catch {
            $hresult = $_.Exception.HResult
            $message = $_.Exception.Message
        } finally {
            if ($null -ne $instance) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($instance)
            }
            $timer.Stop()
        }

        $hex = if ($null -eq $hresult) {
            $null
        } else {
            $unsignedHresult = [uint32](([int64]$hresult) -band 0xffffffffL)
            '0x{0:X8}' -f $unsignedHresult
        }
        $results.Add([pscustomobject]@{
            Scenario = $Scenario
            Iteration = $iteration
            Phase = $phase
            Success = $success
            HResult = $hresult
            Hex = $hex
            Message = $message
            ElapsedMilliseconds = $timer.ElapsedMilliseconds
            Process64Bit = [Environment]::Is64BitProcess
        })
    }
}

$results | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
if (@($results | Where-Object { -not $_.Success }).Count -gt 0) {
    exit 1
}
