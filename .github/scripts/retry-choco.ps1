# Some hosted runners have 8 KiB sectors on C:, which SQL Server cannot use.
for ($attempt = 1; $attempt -le 3; $attempt++) {
  choco install sql-server-express -y --no-progress --install-arguments="/SECURITYMODE=SQL /SAPWD=Password12! /INSTANCEDIR=D:\SQLServer /INSTALLSQLDATADIR=D:\SQLServer" 2>&1 | Tee-Object -Variable output
  $exitCode = $LASTEXITCODE
  if ($exitCode -eq 0) {
    exit 0
  }
  $outputText = $output -join "`n"
  $downloadFailure = $outputText -match 'Unable to connect to source|Unable to read data from the transport connection|The underlying connection was closed|The operation has timed out|The remote name could not be resolved|connection.*(forcibly closed|reset)'
  if (!$downloadFailure -or $outputText -match 'Installing sql-server-express\.\.\.' -or $attempt -eq 3) {
    exit $exitCode
  }
  Write-Host "Retrying SQL Server download in $($attempt * 10) seconds..."
  Start-Sleep -Seconds ($attempt * 10)
}
