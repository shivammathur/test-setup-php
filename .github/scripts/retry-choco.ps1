# Some hosted runners have 8 KiB sectors on C:, which SQL Server cannot use.
$delay = 3
for ($attempt = 1; $attempt -le 3; $attempt++) {
  choco install sql-server-express -y --no-progress --install-arguments="/SECURITYMODE=SQL /SAPWD=Password12! /INSTANCEDIR=D:\SQLServer /INSTALLSQLDATADIR=D:\SQLServer"
  $exitCode = $LASTEXITCODE
  if ($exitCode -eq 0) {
    exit 0
  }
  # Feed failures use generic exit codes. Stop once SQL setup has created its instance directory.
  if ($exitCode -notin @(-1, 1, 404) -or (Test-Path 'D:\SQLServer') -or $attempt -eq 3) {
    exit $exitCode
  }
  Write-Host "Retrying SQL Server setup in $delay seconds..."
  Start-Sleep -Seconds $delay
  $delay *= 2
}
