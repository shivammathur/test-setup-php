$ErrorActionPreference = 'Stop'
if ($env:TEST_SQL_DRIVE -eq 'D') {
    # Exercise the production D: fallback on ordinary 4-KiB runners too.
    function Get-Partition {
        [CmdletBinding()]
        param([string]$DriveLetter)
        if ($DriveLetter -eq 'C') { throw 'C: excluded for the D: installation test' }
        Storage\Get-Partition -DriveLetter $DriveLetter
    }
}
& .github/scripts/windows/setup-mssql.ps1
exit $LASTEXITCODE
