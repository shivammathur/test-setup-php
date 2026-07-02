param(
  [Parameter(Mandatory = $true)]
  [string]$ArtifactsDir
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

$testScript = Resolve-Path -Path 'tests\gd-artifact-smoke.php'
$dynamicLibraryPattern = '^(?:lib)?(?:jxl|heif|tiff|uhdr|ultrahdr|aom|dav1d|de265|x265).*\.dll$'

foreach ($zip in $runtimeZips) {
  Write-Host "::group::$($zip.Name)"
  $extractDir = Join-Path $workDir $zip.BaseName
  Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
  Expand-Archive -Path $zip.FullName -DestinationPath $extractDir -Force

  $php = Join-Path $extractDir 'php.exe'
  $extDir = Join-Path $extractDir 'ext'
  $gdDll = Join-Path $extDir 'php_gd.dll'

  if (!(Test-Path $php)) {
    throw "php.exe not found in $($zip.Name)"
  }
  if (!(Test-Path $gdDll)) {
    throw "php_gd.dll not found in $($zip.Name)"
  }

  $unexpectedDlls = Get-ChildItem -Path $extractDir -Recurse -File -Filter '*.dll' |
    Where-Object { $_.Name -match $dynamicLibraryPattern }
  if ($unexpectedDlls) {
    $found = ($unexpectedDlls | ForEach-Object FullName) -join ', '
    throw "Found unexpected dynamic image library DLLs in $($zip.Name): $found"
  }

  $oldPath = $env:Path
  $env:Path = "$extractDir;$oldPath"
  $env:PHP_GD_DLL = $gdDll

  try {
    & $php -v
    if ($LASTEXITCODE -ne 0) {
      throw "php -v failed for $($zip.Name)"
    }

    $modules = & $php -n -d "extension_dir=$extDir" -d extension=gd -m
    if ($LASTEXITCODE -ne 0) {
      throw "php -m failed for $($zip.Name)"
    }
    if (!(($modules | Where-Object { $_ -eq 'gd' }).Count)) {
      throw "gd module was not listed by php -m for $($zip.Name)"
    }

    $testArgs = @(
      '-n',
      '-d', "extension_dir=$extDir",
      '-d', 'extension=gd',
      '-d', 'error_reporting=-1',
      $testScript
    )

    & $php @testArgs
    if ($LASTEXITCODE -ne 0) {
      throw "GD artifact smoke test failed for $($zip.Name)"
    }
  } finally {
    $env:Path = $oldPath
    Remove-Item Env:PHP_GD_DLL -ErrorAction SilentlyContinue
  }

  Write-Host "::endgroup::"
}
