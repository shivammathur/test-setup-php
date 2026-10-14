param(
  [Parameter(Mandatory)][string] $ArtifactsDirectory,
  [Parameter(Mandatory)][string] $ReportsDirectory,
  [Parameter(Mandatory)][string] $RunId,
  [Parameter(Mandatory)][string] $RunTitle,
  [Parameter(Mandatory)][string] $PhpTarget
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$artifactsPath = (Resolve-Path $ArtifactsDirectory).Path
$reportsPath = [IO.Path]::GetFullPath($ReportsDirectory)
New-Item -ItemType Directory -Force $reportsPath | Out-Null
$zips = @(Get-ChildItem $artifactsPath -Recurse -Filter '*.zip' -File | Where-Object {
  $_.Name -notmatch '^php-(?:debug|devel|test)-pack-' -and
  $_.Name -match '^php-.+?-(?:nts-)?Win32-v[sc]\d+-(?:x64|x86)\.zip$'
})
if ($zips.Count -ne 4) { throw "Expected four runtime ZIPs, found $($zips.Count)" }
$seen = @{}
$failed = $false
$hashes = @()
foreach ($zip in $zips) {
  if ($zip.Name -notmatch '^php-(?<version>.+?)-(?<nts>nts-)?Win32-(?<vs>v[sc]\d+)-(?<arch>x64|x86)\.zip$') { throw 'Invalid runtime ZIP name' }
  $arch = $Matches.arch; $vs = $Matches.vs; $ts = if ($Matches.ContainsKey('nts') -and $Matches.nts) { 'nts' } else { 'ts' }
  if ($seen.ContainsKey("$arch-$ts")) { throw "Duplicate $arch-$ts" }
  $seen["$arch-$ts"] = $true
  $name = $zip.BaseName
  $buildDir = Join-Path $env:RUNNER_TEMP "$RunId/$name"
  $report = Join-Path $reportsPath $name
  New-Item -ItemType Directory -Force $report | Out-Null
  $hashes += @{file=$zip.Name; sha256=(Get-FileHash $zip.FullName -Algorithm SHA256).Hash; run=$RunId}
  $oldPath = $env:PATH
  try {
    Expand-Archive $zip.FullName $buildDir -Force
    $php = Join-Path $buildDir 'php.exe'
    $ini = Join-Path $buildDir 'qa.ini'
    @('[PHP]', "extension_dir=`"$buildDir/ext`"", 'extension=curl', 'extension=gd', 'date.timezone=UTC',
      'display_errors=stderr', 'display_startup_errors=1', 'error_reporting=-1', 'memory_limit=512M', 'zend.assertions=1') | Set-Content $ini
    $env:PATH = "$buildDir;$oldPath"
    $env:WINLIBS_QA_BUILD_DIR = $buildDir
    $env:WINLIBS_QA_PHP_INI = $ini
    $env:WINLIBS_QA_EXPECT_CURL_VERSION = '8.23.0'
    $env:WINLIBS_QA_REPORT_DIR = $report
    Get-ChildItem $buildDir -Recurse -File | Where-Object { $_.Extension -in '.exe','.dll','.json' } | ForEach-Object {
      @{file=[IO.Path]::GetRelativePath($buildDir, $_.FullName); sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash}
    } | ConvertTo-Json -Depth 4 | Set-Content "$report/files.json"
    & $php -c $ini -v *>&1 | Tee-Object "$report/version.txt"
    if ($LASTEXITCODE) { throw 'PHP cannot start' }
    foreach ($extension in @('curl','gd')) {
      $ri = & $php -c $ini --ri $extension
      $ri | Tee-Object "$report/ri-$extension.txt"
      if ($extension -eq 'gd' -and ($ri -join "`n") -notmatch 'FreeType Version => 2\.15\.0(?:\s|$)') { throw 'GD must link FreeType 2.15.0' }
      if ($LASTEXITCODE) { throw "Cannot load $extension" }
    }
    & $php -c $ini tests/winlibs-deps-exhaustive.php --junit "$report/junit.xml" --json "$report/result.json" `
      --run-id $RunId --run-title $RunTitle --php-target $PhpTarget --artifact $zip.Name --arch $arch --ts $ts --vs $vs *>&1 | Tee-Object "$report/suite.log"
    if ($LASTEXITCODE) { $failed = $true }
    $smb = if ($PhpTarget -in '8.2','8.3','8.4','8.5') { 'true' } else { 'false' }
    python scripts/check-smb.py --php $php --ini $ini --expect-smb $smb --report "$report/smb.json"
    if ($LASTEXITCODE) { $failed = $true }
  } catch {
    $failed = $true
    Write-Host "::error::$name`: $_"
  } finally {
    $env:PATH = $oldPath
  }
}
$hashes | ConvertTo-Json -Depth 4 | Set-Content "$reportsPath/artifact-hashes.json"
foreach ($variant in @('x64-ts','x64-nts','x86-ts','x86-nts')) {
  if (!$seen.ContainsKey($variant)) { throw "Missing $variant" }
}
if ($failed) { throw 'One or more artifact QA suites failed' }
