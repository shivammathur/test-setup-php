param([switch]$Restart)
$ErrorActionPreference = 'Stop'
$architecture = $env:PROCESSOR_ARCHITECTURE
$diagnostics = Join-Path $env:RUNNER_TEMP 'setup-diagnostics'
$installDir = "$($env:EXPECTED_SQL_DRIVE):\SQLServer\"
if ($Restart) {
    Restart-Service -Name 'MSSQL$SQLEXPRESS' -Force
    (Get-Service -Name 'MSSQL$SQLEXPRESS').WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
}
$service = Get-CimInstance Win32_Service -Filter 'Name = ''MSSQL$SQLEXPRESS'''
if ($service.State -ne 'Running' -or !$service.PathName.Contains($installDir)) {
    throw "SQL service is not running from ${installDir}: $($service | ConvertTo-Json -Compress)"
}
$service | Select-Object Name, State, StartName, PathName | ConvertTo-Json | Out-File "$diagnostics\sql-service-$architecture.json"
$connection = [System.Data.Odbc.OdbcConnection]::new('Driver={ODBC Driver 17 for SQL Server};Server=(local)\SQLEXPRESS;Database=master;uid=sa;pwd=Password12!;Connection Timeout=30')
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = 'SELECT @@VERSION'
    $command.ExecuteScalar() | Tee-Object "$diagnostics\sql-version-$architecture.txt"
    function Read-DatabaseFiles([string]$query) {
        $command.CommandText = $query
        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                $path = $reader.GetString(2)
                if (!$path.StartsWith($installDir, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Database file is outside ${installDir}: $path"
                }
                [pscustomobject]@{ Database = $reader.GetString(0); Name = $reader.GetString(1); Path = $path }
            }
        } finally { $reader.Close() }
    }
    $files = @(Read-DatabaseFiles 'SELECT DB_NAME(database_id), name, physical_name FROM sys.master_files WHERE database_id <= 4')
    if ($files.Count -ne 8) { throw "Expected 8 system database files, got $($files.Count)" }
    $files | ConvertTo-Json | Out-File "$diagnostics\database-paths-$architecture.json"
    if (!(Test-Path "${installDir}MSSQL16.SQLEXPRESS\MSSQL\Template Data\master.mdf")) {
        throw "SQL template master.mdf is missing from $installDir"
    }
    $command.CommandText = 'CREATE DATABASE [php_sql_location_probe]'
    [void]$command.ExecuteNonQuery()
    try {
        $probeFiles = @(Read-DatabaseFiles "SELECT DB_NAME(database_id), name, physical_name FROM sys.master_files WHERE DB_NAME(database_id) = 'php_sql_location_probe'")
        if ($probeFiles.Count -ne 2) { throw 'New database did not create its data and log files' }
        $probeFiles | ConvertTo-Json | Out-File "$diagnostics\new-database-paths-$architecture.json"
    } finally {
        $command.CommandText = 'DROP DATABASE [php_sql_location_probe]'
        [void]$command.ExecuteNonQuery()
    }
    Write-Host "PASS: $architecture ODBC, service executable, templates, 8 system files, and new database creation on $installDir"
} finally { $connection.Dispose() }
