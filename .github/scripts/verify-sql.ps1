$ErrorActionPreference = 'Stop'
$connection = [System.Data.Odbc.OdbcConnection]::new('Driver={ODBC Driver 17 for SQL Server};Server=(local)\SQLEXPRESS;Database=master;uid=sa;pwd=Password12!;Connection Timeout=10')
$architecture = $env:PROCESSOR_ARCHITECTURE
$diagnostics = Join-Path $env:RUNNER_TEMP 'setup-diagnostics'
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = 'SELECT @@VERSION'
    $command.ExecuteScalar() | Tee-Object "$diagnostics\sql-version-$architecture.txt"
    $physicalSizes = @{}
    foreach ($letter in 'C', 'D') {
        if (Test-Path "${letter}:\") {
            $disk = Get-Partition -DriveLetter $letter | Get-Disk
            $physicalSizes[$letter] = [int]$disk.PhysicalSectorSize
        }
    }
    $expectedDrive = @('C', 'D') | Where-Object { $physicalSizes[$_] -in @(512, 4096) } | Select-Object -First 1
    $expectedDir = "${expectedDrive}:\SQLServer\"
    $physicalSizes | ConvertTo-Json | Out-File "$diagnostics\physical-sectors-$architecture.json"
    $command.CommandText = 'SELECT DB_NAME(database_id), name, physical_name FROM sys.master_files WHERE database_id <= 4'
    $reader = $command.ExecuteReader()
    $files = @()
    while ($reader.Read()) {
        $path = $reader.GetString(2)
        if (!$path.StartsWith($expectedDir, [StringComparison]::OrdinalIgnoreCase)) {
            throw "System database file is outside ${expectedDir}: $path"
        }
        $files += [pscustomobject]@{ Database = $reader.GetString(0); Name = $reader.GetString(1); Path = $path }
    }
    $reader.Close()
    $files | ConvertTo-Json | Out-File "$diagnostics\database-paths-$architecture.json"
    if (!(Test-Path "${expectedDir}MSSQL16.SQLEXPRESS\MSSQL\Template Data\master.mdf")) {
        throw "SQL template master.mdf is missing from $expectedDir"
    }
    Write-Host "Verified $architecture ODBC connection, SQL templates, and $($files.Count) system database files on ${expectedDrive}:"
} finally {
    $connection.Dispose()
}
