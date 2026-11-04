$connection = [System.Data.Odbc.OdbcConnection]::new('Driver={ODBC Driver 17 for SQL Server};Server=(local)\SQLEXPRESS;Database=master;uid=sa;pwd=Password12!;Connection Timeout=10')
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = 'SELECT @@VERSION'
    $command.ExecuteScalar() | Tee-Object (Join-Path $env:RUNNER_TEMP 'setup-diagnostics\sql-version.txt')
} finally {
    $connection.Dispose()
}
