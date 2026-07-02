param(
  [Parameter(Mandatory = $true)]
  [string]$ArtifactsDir,

  [switch]$AllowNonOpenSsl4
)

$ErrorActionPreference = 'Stop'

$artifactsPath = Resolve-Path -Path $ArtifactsDir
$workDir = Join-Path $PWD 'php-builds'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$runtimeZips = Get-ChildItem -Path $artifactsPath -Filter 'php-*.zip' -File |
  Where-Object {
    $_.Name -match '^php-\d+\.\d+\.\d+(?:-[^-]+)?(?:-nts)?-Win32-vs1[78]-(x64|x86)\.zip$'
  } |
  Sort-Object Name

if ($runtimeZips.Count -ne 4) {
  $found = ($runtimeZips | ForEach-Object Name) -join ', '
  throw "Expected 4 runtime PHP artifacts, found $($runtimeZips.Count): $found"
}

$testScript = Resolve-Path -Path 'tests\openssl-artifact-smoke.php'

foreach ($zip in $runtimeZips) {
  Write-Host "::group::$($zip.Name)"
  $extractDir = Join-Path $workDir $zip.BaseName
  Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
  Expand-Archive -Path $zip.FullName -DestinationPath $extractDir -Force

  $php = Join-Path $extractDir 'php.exe'
  $extDir = Join-Path $extractDir 'ext'
  if (!(Test-Path $php)) {
    throw "php.exe not found in $($zip.Name)"
  }
  if (!(Test-Path (Join-Path $extDir 'php_openssl.dll'))) {
    throw "php_openssl.dll not found in $($zip.Name)"
  }

  & $php -v
  if ($LASTEXITCODE -ne 0) {
    throw "php -v failed for $($zip.Name)"
  }

  & $php -n -d "extension_dir=$extDir" -d extension=openssl -m
  if ($LASTEXITCODE -ne 0) {
    throw "php -m failed for $($zip.Name)"
  }

  $testArgs = @(
    '-n',
    '-d', "extension_dir=$extDir",
    '-d', 'extension=openssl',
    '-d', 'error_reporting=-1',
    $testScript
  )
  if ($AllowNonOpenSsl4) {
    $testArgs += '--allow-non-openssl4'
  }

  & $php @testArgs
  if ($LASTEXITCODE -ne 0) {
    throw "OpenSSL smoke test failed for $($zip.Name)"
  }

  Write-Host "::endgroup::"
}
