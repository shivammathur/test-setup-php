param(
  [Parameter(Mandatory = $true)]
  [string] $ArtifactsDirectory,

  [Parameter(Mandatory = $true)]
  [string] $ReportsDirectory,

  [Parameter(Mandatory = $true)]
  [string] $RunId,

  [Parameter(Mandatory = $true)]
  [string] $RunTitle,

  [Parameter(Mandatory = $true)]
  [string] $PhpTarget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string] $Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Expand-Zip {
  param(
    [Parameter(Mandatory = $true)][string] $Zip,
    [Parameter(Mandatory = $true)][string] $Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  try {
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
  } catch {
    $output = & 7z x $Zip "-o$Destination" -y 2>&1
    $exitCode = $LASTEXITCODE
    $output | Out-Host
    if ($exitCode -gt 1) {
      throw "7z failed extracting $Zip with exit code $exitCode"
    }
  }
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

function Write-HunspellDictionary {
  param(
    [Parameter(Mandatory = $true)][string] $DictionaryDirectory
  )

  New-Item -ItemType Directory -Force -Path $DictionaryDirectory | Out-Null
  @(
    'SET UTF-8',
    'FLAG UTF-8',
    'TRY esianrtolcdugmphbyfvkw',
    ''
  ) | Set-Content -LiteralPath (Join-Path $DictionaryDirectory 'en_US.aff') -Encoding ASCII

  @(
    '9',
    'hello',
    'world',
    'color',
    'colour',
    'example',
    'testing',
    'artifact',
    'winlibs',
    'dependency'
  ) | Set-Content -LiteralPath (Join-Path $DictionaryDirectory 'en_US.dic') -Encoding ASCII
}

function Prepare-EnchantRuntime {
  param(
    [Parameter(Mandatory = $true)][string] $PhpDirectory
  )

  $plugin = Get-ChildItem -LiteralPath $PhpDirectory -Recurse -Filter 'libenchant2_hunspell.dll' -File -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $plugin) {
    throw "libenchant2_hunspell.dll was not found under $PhpDirectory"
  }

  $moduleDir = Join-Path $PhpDirectory 'qa-enchant-modules'
  New-Item -ItemType Directory -Force -Path $moduleDir | Out-Null
  Copy-Item -LiteralPath $plugin.FullName -Destination $moduleDir -Force

  $dictionaryDir = Join-Path $PhpDirectory 'qa-hunspell-dictionaries'
  Write-HunspellDictionary -DictionaryDirectory $dictionaryDir

  return [PSCustomObject]@{
    ModulePath = "$moduleDir;$($plugin.DirectoryName)"
    DllPath = "$moduleDir;$($plugin.DirectoryName)"
    DictionaryPath = $dictionaryDir
  }
}

function Get-Variant {
  param([Parameter(Mandatory = $true)][string] $ZipName)

  if ($ZipName -notmatch '^php-(?<version>.+?)-(?<nts>nts-)?Win32-(?<vs>v[sc]\d+)-(?<arch>x64|x86)\.zip$') {
    throw "Unexpected PHP artifact zip name: $ZipName"
  }

  return [PSCustomObject]@{
    Version = $Matches.version
    Vs = $Matches.vs
    Arch = $Matches.arch
    Ts = if ($Matches.ContainsKey('nts') -and $Matches['nts']) { 'nts' } else { 'ts' }
  }
}

$artifactsPath = Resolve-FullPath $ArtifactsDirectory
$reportsPath = Resolve-FullPath $ReportsDirectory
$suitePath = Resolve-FullPath 'tests/winlibs-deps-exhaustive.php'

if (!(Test-Path -LiteralPath $artifactsPath -PathType Container)) {
  throw "Artifacts directory '$artifactsPath' does not exist"
}
if (!(Test-Path -LiteralPath $suitePath -PathType Leaf)) {
  throw "Test suite '$suitePath' does not exist"
}

New-Item -ItemType Directory -Force -Path $reportsPath | Out-Null

$runReport = Join-Path $reportsPath 'run.txt'
"Run: $RunId" | Set-Content -LiteralPath $runReport -Encoding ASCII
"Title: $RunTitle" | Add-Content -LiteralPath $runReport -Encoding ASCII
"Target: $PhpTarget" | Add-Content -LiteralPath $runReport -Encoding ASCII
"Artifact zips:" | Add-Content -LiteralPath $runReport -Encoding ASCII

$allZips = Get-ChildItem -LiteralPath $artifactsPath -Recurse -Filter '*.zip' -File | Sort-Object Name
$allZips | ForEach-Object { "  $($_.Name) $($_.Length) bytes" | Add-Content -LiteralPath $runReport -Encoding ASCII }

$zips = $allZips |
  Where-Object {
    $_.Name -notmatch '^php-(?:debug|devel|test)-pack-' -and
    $_.Name -match '^php-.+?-(?:nts-)?Win32-v[sc]\d+-(?:x64|x86)\.zip$'
  } |
  Sort-Object Name

if ($zips.Count -ne 4) {
  $found = ($zips | ForEach-Object { $_.FullName }) -join [Environment]::NewLine
  throw "Expected exactly 4 PHP build zips (x64/x86 ts/nts), found $($zips.Count):$([Environment]::NewLine)$found"
}

$seen = @{}
foreach ($zip in $zips) {
  $variant = Get-Variant -ZipName $zip.Name
  $seen["$($variant.Arch)-$($variant.Ts)"] = $zip.Name
}
foreach ($required in @('x64-ts', 'x64-nts', 'x86-ts', 'x86-nts')) {
  if (!$seen.ContainsKey($required)) {
    throw "Missing required PHP artifact variant '$required'"
  }
}

"Selected runtime zips:" | Add-Content -LiteralPath $runReport -Encoding ASCII
$zips | ForEach-Object { "  $($_.Name) $($_.Length) bytes" | Add-Content -LiteralPath $runReport -Encoding ASCII }

$failed = $false
$extractRoot = Join-Path $env:RUNNER_TEMP "winlibs-deps-exhaustive-$RunId"
if (Test-Path -LiteralPath $extractRoot) {
  Remove-Item -LiteralPath $extractRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

foreach ($zip in $zips) {
  $variant = Get-Variant -ZipName $zip.Name
  $buildName = [System.IO.Path]::GetFileNameWithoutExtension($zip.Name)
  $buildDir = Join-Path $extractRoot $buildName
  $buildReportDir = Join-Path $reportsPath $buildName
  New-Item -ItemType Directory -Force -Path $buildReportDir | Out-Null

  Write-Host "::group::$($zip.Name)"
  try {
    Expand-Zip -Zip $zip.FullName -Destination $buildDir

    $php = Join-Path $buildDir 'php.exe'
    $extDir = Join-Path $buildDir 'ext'
    if (!(Test-Path -LiteralPath $php -PathType Leaf)) {
      throw "php.exe was not found after extracting $($zip.Name)"
    }
    if (!(Test-Path -LiteralPath $extDir -PathType Container)) {
      throw "Extension directory was not found after extracting $($zip.Name)"
    }

    Get-ChildItem -LiteralPath $buildDir -Recurse -File |
      Sort-Object FullName |
      Select-Object FullName, Length |
      Format-Table -AutoSize |
      Out-String -Width 240 |
      Set-Content -LiteralPath (Join-Path $buildReportDir 'files.txt') -Encoding UTF8

    $enchantRuntime = Prepare-EnchantRuntime -PhpDirectory $buildDir

    $ini = Join-Path $buildDir 'winlibs-deps-exhaustive.ini'
    $iniLines = [System.Collections.Generic.List[string]]::new()
    $iniLines.Add('[PHP]')
    $iniLines.Add("extension_dir=`"$extDir`"")
    $iniLines.Add('date.timezone=UTC')
    $iniLines.Add('display_errors=1')
    $iniLines.Add('display_startup_errors=1')
    $iniLines.Add('error_reporting=-1')
    $iniLines.Add('memory_limit=512M')
    $iniLines.Add('ffi.enable=true')
    $iniLines.Add('zend.assertions=1')
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'curl'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'ffi'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'gd'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'enchant'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'intl'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'tidy'
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'readline' -Required $false
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'zlib' -Required $false
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'mbstring' -Required $false
    Add-PhpExtension -Lines $iniLines -ExtensionDirectory $extDir -Name 'exif' -Required $false
    $iniLines | Set-Content -LiteralPath $ini -Encoding ASCII

    $oldPath = $env:PATH
    $oldEnchantModulePath = $env:ENCHANT_MODULE_PATH
    $oldDicPath = $env:DICPATH
    $oldDictPath = $env:DICTPATH
    $oldEnchantConfigDir = $env:ENCHANT_CONFIG_DIR
    $oldWinlibsBuildDir = $env:WINLIBS_QA_BUILD_DIR
    $oldWinlibsArtifact = $env:WINLIBS_QA_ARTIFACT
    $oldWinlibsRun = $env:WINLIBS_QA_RUN_ID
    $oldWinlibsIni = $env:WINLIBS_QA_PHP_INI
    $oldWinlibsIntlRi = $env:WINLIBS_QA_INTL_RI
    $oldWinlibsTidyRi = $env:WINLIBS_QA_TIDY_RI

    $env:PATH = "$buildDir;$($enchantRuntime.DllPath);$env:SystemRoot\System32;$oldPath"
    $env:ENCHANT_MODULE_PATH = $enchantRuntime.ModulePath
    $env:DICPATH = $enchantRuntime.DictionaryPath
    $env:DICTPATH = $enchantRuntime.DictionaryPath
    $env:ENCHANT_CONFIG_DIR = $buildDir
    $env:WINLIBS_QA_BUILD_DIR = $buildDir
    $env:WINLIBS_QA_ARTIFACT = $zip.Name
    $env:WINLIBS_QA_RUN_ID = $RunId
    $env:WINLIBS_QA_PHP_INI = $ini
    $env:WINLIBS_QA_INTL_RI = Join-Path $buildReportDir 'ri-intl.txt'
    $env:WINLIBS_QA_TIDY_RI = Join-Path $buildReportDir 'ri-tidy.txt'

    try {
      & $php -c $ini -v *>&1 | Tee-Object -FilePath (Join-Path $buildReportDir 'php-version.txt')
      if ($LASTEXITCODE -ne 0) { throw "php -v failed for $($zip.Name)" }

      $modulesOutput = & $php -c $ini -m *>&1
      $modulesOutput | Tee-Object -FilePath (Join-Path $buildReportDir 'php-modules.txt')
      if ($LASTEXITCODE -ne 0) { throw "php -m failed for $($zip.Name)" }

      $riExtensions = [System.Collections.Generic.List[string]]::new()
      foreach ($extension in @('curl', 'ffi', 'gd', 'enchant', 'intl', 'tidy')) {
        $riExtensions.Add($extension)
      }
      if ($modulesOutput -contains 'readline') {
        $riExtensions.Add('readline')
      }
      foreach ($extension in $riExtensions) {
        $riOutput = & $php -c $ini --ri $extension *>&1
        $riOutput | Tee-Object -FilePath (Join-Path $buildReportDir "ri-$extension.txt")
        if ($LASTEXITCODE -ne 0) { throw "php --ri $extension failed for $($zip.Name)" }
      }

      $junit = Join-Path $buildReportDir 'junit.xml'
      $json = Join-Path $buildReportDir 'result.json'
      $log = Join-Path $buildReportDir 'suite.log'
      & $php -c $ini $suitePath `
        --junit $junit `
        --json $json `
        --run-id $RunId `
        --run-title $RunTitle `
        --php-target $PhpTarget `
        --artifact $zip.Name `
        --arch $variant.Arch `
        --ts $variant.Ts `
        --vs $variant.Vs *>&1 |
        Tee-Object -FilePath $log
      if ($LASTEXITCODE -ne 0) {
        $failed = $true
      }
    } finally {
      $env:PATH = $oldPath
      $env:ENCHANT_MODULE_PATH = $oldEnchantModulePath
      $env:DICPATH = $oldDicPath
      $env:DICTPATH = $oldDictPath
      $env:ENCHANT_CONFIG_DIR = $oldEnchantConfigDir
      $env:WINLIBS_QA_BUILD_DIR = $oldWinlibsBuildDir
      $env:WINLIBS_QA_ARTIFACT = $oldWinlibsArtifact
      $env:WINLIBS_QA_RUN_ID = $oldWinlibsRun
      $env:WINLIBS_QA_PHP_INI = $oldWinlibsIni
      $env:WINLIBS_QA_INTL_RI = $oldWinlibsIntlRi
      $env:WINLIBS_QA_TIDY_RI = $oldWinlibsTidyRi
    }
  } catch {
    $failed = $true
    $message = $_.Exception.Message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "::error title=$($zip.Name)::$message"
    Write-Warning ($_ | Out-String)
  } finally {
    Write-Host '::endgroup::'
  }
}

if ($failed) {
  throw 'One or more Winlibs dependency exhaustive QA suites failed'
}
