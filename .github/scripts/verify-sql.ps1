$ErrorActionPreference = 'Stop'
$connection = [System.Data.Odbc.OdbcConnection]::new('Driver={ODBC Driver 17 for SQL Server};Server=(local)\SQLEXPRESS;Database=master;uid=sa;pwd=Password12!;Connection Timeout=10')
$architecture = $env:PROCESSOR_ARCHITECTURE
$diagnostics = Join-Path $env:RUNNER_TEMP 'setup-diagnostics'
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = 'SELECT @@VERSION'
    $command.ExecuteScalar() | Tee-Object "$diagnostics\sql-version-$architecture.txt"
    $command.CommandText = 'SELECT DB_NAME(database_id), name, physical_name FROM sys.master_files WHERE database_id <= 4'
    $reader = $command.ExecuteReader()
    $files = @()
    while ($reader.Read()) {
        $path = $reader.GetString(2)
        if (!$path.StartsWith('D:\SQLServer\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "System database file is outside D:\SQLServer: $path"
        }
        $files += [pscustomobject]@{ Database = $reader.GetString(0); Name = $reader.GetString(1); Path = $path }
    }
    $reader.Close()
    $files | ConvertTo-Json | Out-File "$diagnostics\database-paths-$architecture.json"
    if (!(Test-Path 'D:\SQLServer\MSSQL16.SQLEXPRESS\MSSQL\Template Data\master.mdf')) {
        throw 'SQL template master.mdf is missing from D:\SQLServer'
    }
    Write-Host "Verified $architecture ODBC connection, SQL templates, and $($files.Count) system database files on D:"
} finally {
    $connection.Dispose()
}
