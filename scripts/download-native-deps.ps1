param(
  [Parameter(Mandatory)][string]$Library,
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$Php,
  [Parameter(Mandatory)][string]$Vs,
  [Parameter(Mandatory)][string]$Arch,
  [string]$OpenSslRun
)
$ErrorActionPreference = 'Stop'
New-Item reports, product, deps -ItemType Directory -Force | Out-Null
$deadline = (Get-Date).AddMinutes(50)
while ((Get-Date) -lt $deadline) {
  $run = gh api "repos/winlibs/winlib-builder/actions/runs/$RunId" | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw "Unable to inspect $RunId" }
  if ($run.status -eq 'completed') {
    if ($run.conclusion -ne 'success') { throw "Library build failed: $RunId" }
    break
  }
  Start-Sleep -Seconds 30
}
if ($run.conclusion -ne 'success') { throw 'Timed out waiting for library build' }
$run | ConvertTo-Json -Depth 30 | Set-Content reports/build-run.json
$artifacts = gh api "repos/winlibs/winlib-builder/actions/runs/$RunId/artifacts" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect artifact metadata' }
$matches = @($artifacts.artifacts | Where-Object { $_.name -like "*-$Vs-$Arch" -and -not $_.expired })
if ($matches.Count -ne 1) { throw "Expected exactly one library artifact: $($matches.Count)" }
$matches[0] | ConvertTo-Json -Depth 20 | Set-Content reports/build-artifact.json
gh run download $RunId -R winlibs/winlib-builder -n $matches[0].name -D product
if ($LASTEXITCODE -ne 0) { throw 'Library artifact download failed' }
if ($OpenSslRun) {
  $sslArtifacts = gh api "repos/winlibs/winlib-builder/actions/runs/$OpenSslRun/artifacts" | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'OpenSSL metadata download failed' }
  $ssl = @($sslArtifacts.artifacts | Where-Object { $_.name -like "openssl-*-$Vs-$Arch" -and -not $_.expired })
  if ($ssl.Count -ne 1) { throw 'Unexpected OpenSSL artifacts' }
  gh run download $OpenSslRun -R winlibs/winlib-builder -n $ssl[0].name -D deps
  if ($LASTEXITCODE -ne 0) { throw 'OpenSSL artifact download failed' }
} elseif ($Library -eq 'librrd') {
  $base = 'https://downloads.php.net/~windows/php-sdk/deps'
  $series = (Invoke-WebRequest "$base/series/packages-$Php-$Vs-$Arch-staging.txt").Content -split '[\r\n]+'
  foreach ($dep in @('glib', 'libffi', 'libintl')) {
    $selected = @($series | Where-Object { $_ -match "^$dep-.*-$Vs-$Arch\.zip$" })
    if ($selected.Count -ne 1) { throw "Expected one staged $dep" }
    $file = Join-Path $env:RUNNER_TEMP $selected[0]
    Invoke-WebRequest "$base/$Vs/$Arch/$($selected[0])" -OutFile $file
    Expand-Archive $file -DestinationPath deps -Force
  }
}
Get-ChildItem product, deps -Recurse -File | Get-FileHash -Algorithm SHA256 |
  ConvertTo-Json | Set-Content reports/input-sha256.json
