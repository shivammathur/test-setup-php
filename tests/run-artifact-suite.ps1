param(
  [Parameter(Mandatory = $true)]
  [string] $ArtifactsDirectory,

  [Parameter(Mandatory = $true)]
  [string] $ReportsDirectory,

  [Parameter(Mandatory = $true)]
  [string] $RunId,

  [Parameter(Mandatory = $true)]
  [string] $RunTitle
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string] $Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Add-PhpExtension {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.Generic.List[string]] $Lines,

    [Parameter(Mandatory = $true)]
    [string] $ExtensionDirectory,

    [Parameter(Mandatory = $true)]
    [string] $Name,

    [bool] $Required = $true
  )

  $dll = Join-Path $ExtensionDirectory "php_$Name.dll"
  if (Test-Path -LiteralPath $dll -PathType Leaf) {
    $Lines.Add("extension=$Name")
    return
  }

  if ($Required) {
    throw "Required extension php_$Name.dll was not found in $ExtensionDirectory"
  }
}

$artifactsPath = Resolve-FullPath $ArtifactsDirectory
$reportsPath = Resolve-FullPath $ReportsDirectory
$suitePath = Resolve-FullPath 'tests/php-artifact-library-suite.php'

if (!(Test-Path -LiteralPath $artifactsPath -PathType Container)) {
  throw "Artifacts directory '$artifactsPath' does not exist"
}
if (!(Test-Path -LiteralPath $suitePath -PathType Leaf)) {
  throw "Test suite '$suitePath' does not exist"
}

New-Item -ItemType Directory -Force -Path $reportsPath | Out-Null

$allZips = Get-ChildItem -LiteralPath $artifactsPath -Recurse -Filter 'php-*.zip' -File | Sort-Object Name
"Run: $RunId" | Set-Content -LiteralPath (Join-Path $reportsPath 'run.txt')
"Title: $RunTitle" | Add-Content -LiteralPath (Join-Path $reportsPath 'run.txt')
"Artifact zips:" | Add-Content -LiteralPath (Join-Path $reportsPath 'run.txt')
$allZips | ForEach-Object { "  $($_.Name) $($_.Length) bytes" | Add-Content -LiteralPath (Join-Path $reportsPath 'run.txt') }

$zips = $allZips |
  Where-Object {
    $_.Name -notmatch '^php-(?:debug|devel|test)-pack-' -and
    $_.Name -match '^php-.+?-(?:nts-)?Win32-v[sc]\d+-(?:x64|x86)\.zip$'
  } |
  Sort-Object Name

if ($zips.Count -ne 4) {
  $found = ($zips | ForEach-Object { $_.FullName }) -join [Environment]::NewLine
  throw "Expected exactly 4 PHP build zips (x64/x86 ts/nts) in '$artifactsPath', found $($zips.Count):$([Environment]::NewLine)$found"
}

$seen = @{}
foreach ($zip in $zips) {
  if ($zip.Name -match '^php-.+?-(?<nts>nts-)?Win32-v[sc]\d+-(?<arch>x64|x86)\.zip$') {
    $ts = if ($Matches['nts']) { 'nts' } else { 'ts' }
    $seen["$($Matches['arch'])-$ts"] = $zip.Name
  } else {
    throw "Unexpected PHP zip name '$($zip.Name)'"
  }
}

foreach ($required in @('x64-ts', 'x64-nts', 'x86-ts', 'x86-nts')) {
  if (!$seen.ContainsKey($required)) {
    throw "Missing required PHP artifact variant '$required'"
  }
}

"Selected runtime zips:" | Add-Content -LiteralPath (Join-Path $reportsPath 'run.txt')
$zips | ForEach-Object { "  $($_.Name) $($_.Length) bytes" | Add-Content -LiteralPath (Join-Path $reportsPath 'run.txt') }

$failed = $false
$extractRoot = Join-Path $env:RUNNER_TEMP "php-artifact-library-qa-$RunId"
if (Test-Path -LiteralPath $extractRoot) {
  Remove-Item -LiteralPath $extractRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

foreach ($zip in $zips) {
  $buildName = [System.IO.Path]::GetFileNameWithoutExtension($zip.Name)
  $buildDir = Join-Path $extractRoot $buildName
  $buildReportDir = Join-Path $reportsPath $buildName
  New-Item -ItemType Directory -Force -Path $buildReportDir | Out-Null

  Write-Host "::group::$($zip.Name)"
  try {
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $buildDir -Force

    $php = Join-Path $buildDir 'php.exe'
    $extDir = Join-Path $buildDir 'ext'
    if (!(Test-Path -LiteralPath $php -PathType Leaf)) {
      throw "php.exe was not found after extracting $($zip.Name)"
    }
    if (!(Test-Path -LiteralPath $extDir -PathType Container)) {
      throw "Extension directory was not found after extracting $($zip.Name)"
    }

    $ini = Join-Path $buildDir 'php-library-qa.ini'
    $iniLines = [System.Collections.Generic.List[string]]::new()
    $iniLines.Add('[PHP]')
    $iniLines.Add("extension_dir=`"$extDir`"")
    $iniLines.Add('date.timezone=UTC')
    $iniLines.Add('display_errors=1')
    $iniLines.Add('display_startup_errors=1')
    $iniLines.Add('error_reporting=-1')
    $iniLines.Add('memory_limit=512M')
    $iniLines.Add('zend.assertions=1')
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'mbstring' -Required $false
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'exif' -Required $false
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'sqlite3'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'pdo_sqlite'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'gd'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'ldap'
    $iniLines | Set-Content -LiteralPath $ini -Encoding ASCII

    $oldPath = $env:PATH
    $oldSaslPath = $env:SASL_PATH
    $oldCyrusSaslPath = $env:CYRUS_SASL_PATH
    $env:PATH = "$buildDir;$oldPath"
    try {
      Get-ChildItem -LiteralPath $buildDir -Recurse -File |
        Where-Object { $_.Name -match 'sasl|ldap' } |
        Select-Object FullName, Length |
        Format-Table -AutoSize |
        Out-String |
        Set-Content -LiteralPath (Join-Path $buildReportDir 'sasl-ldap-files.txt')

      $saslPluginDir = Get-ChildItem -LiteralPath $buildDir -Directory -Recurse |
        Where-Object { $_.Name -in @('sasl2', 'sasl') } |
        Select-Object -First 1
      if ($null -ne $saslPluginDir) {
        $env:SASL_PATH = $saslPluginDir.FullName
        $env:CYRUS_SASL_PATH = $saslPluginDir.FullName
      } else {
        $env:SASL_PATH = $buildDir
        $env:CYRUS_SASL_PATH = $buildDir
      }
      "SASL_PATH=$($env:SASL_PATH)" | Set-Content -LiteralPath (Join-Path $buildReportDir 'sasl-path.txt')
      "CYRUS_SASL_PATH=$($env:CYRUS_SASL_PATH)" | Add-Content -LiteralPath (Join-Path $buildReportDir 'sasl-path.txt')

      & $php -c $ini -v *>&1 | Tee-Object -FilePath (Join-Path $buildReportDir 'php-version.txt')
      if ($LASTEXITCODE -ne 0) {
        throw "php -v failed for $($zip.Name)"
      }

      & $php -c $ini -m *>&1 | Tee-Object -FilePath (Join-Path $buildReportDir 'php-modules.txt')
      if ($LASTEXITCODE -ne 0) {
        throw "php -m failed for $($zip.Name)"
      }

      & $php -c $ini --ri ldap *>&1 | Tee-Object -FilePath (Join-Path $buildReportDir 'ldap-info.txt')

      $junit = Join-Path $buildReportDir 'junit.xml'
      $log = Join-Path $buildReportDir 'suite.log'
      & $php -c $ini $suitePath --junit $junit --run-id $RunId --build $zip.Name *>&1 |
        Tee-Object -FilePath $log
      if ($LASTEXITCODE -ne 0) {
        $failed = $true
      }
    } finally {
      $env:PATH = $oldPath
      $env:SASL_PATH = $oldSaslPath
      $env:CYRUS_SASL_PATH = $oldCyrusSaslPath
    }
  } catch {
    $failed = $true
    Write-Host "::error title=$($zip.Name)::$(($_.Exception.Message) -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A')"
    Write-Warning ($_ | Out-String)
  } finally {
    Write-Host '::endgroup::'
  }
}

if ($failed) {
  throw 'One or more PHP artifact library QA suites failed'
}
