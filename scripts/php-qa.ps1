param([string]$ArtifactsDirectory,[string]$RunId,[string]$PhpTarget)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force reports | Out-Null
$root=(Get-Location).Path
$zips=@(Get-ChildItem $ArtifactsDirectory -Recurse -File -Filter '*.zip' | Where-Object {$_.Name -match '^php-.+?-(?:nts-)?Win32-v[sc]\d+-(?:x64|x86)\.zip$' -and $_.Name -notmatch '^php-(debug|devel|test)-pack-'})
if($zips.Count -ne 4){throw "Expected four runtime ZIPs, found $($zips.Count)"}
$seen=@{};$failed=$false;$hashes=@()
foreach($zip in $zips) {
  if($zip.Name -notmatch '^php-(?<version>.+?)-(?<nts>nts-)?Win32-(?<vs>v[sc]\d+)-(?<arch>x64|x86)\.zip$'){throw 'Invalid runtime name'}
  $arch=$Matches.arch;$vs=$Matches.vs;$ts=if($Matches.ContainsKey('nts') -and $Matches.nts){'nts'}else{'ts'}
  if($seen.ContainsKey("$arch-$ts")){throw 'Duplicate variant'};$seen["$arch-$ts"]=$true
  $build=Join-Path $env:RUNNER_TEMP "$RunId/$($zip.BaseName)"
  $report="$root/reports/$arch-$ts";New-Item -ItemType Directory -Force $report | Out-Null
  $hashes+=@{file=$zip.Name;sha256=(Get-FileHash $zip.FullName -Algorithm SHA256).Hash;run=$RunId}
  $oldPath=$env:PATH
  try {
    Expand-Archive $zip.FullName $build -Force
    $php="$build/php.exe";$ini="$build/qa.ini"
    @('[PHP]',"extension_dir=`"$build/ext`"",'extension=curl','extension=gd','extension=zip','date.timezone=UTC','display_errors=stderr','display_startup_errors=1','error_reporting=-1','memory_limit=512M') | Set-Content $ini
    $env:PATH="$build;$oldPath"
    & $php -c $ini -v | Tee-Object "$report/version.txt"
    if($LASTEXITCODE){throw 'PHP failed to start'}
    foreach($ext in @('curl','gd','zip')) { & $php -c $ini --ri $ext | Tee-Object "$report/ri-$ext.txt";if($LASTEXITCODE){throw "Failed loading $ext"} }
    python scripts/verify-php.py --directory $build --vs $vs --arch $arch --php $PhpTarget --report "$report/provenance.json"
    if($LASTEXITCODE){throw 'PHP artifact provenance failed'}
    python scripts/http-qa.py --php $php --ini $ini --fixtures tests/fixtures --report "$report/http.json"
    if($LASTEXITCODE){throw 'PHP HTTP Brotli integration failed'}
    & $php -c $ini tests/php-libzip.php "$report/libzip.json"
    if($LASTEXITCODE){throw 'PHP ZipArchive integration failed'}
  } catch {$failed=$true;$_ | Out-String | Set-Content "$report/error.txt";Write-Host "::error::$arch-$ts $_"} finally {$env:PATH=$oldPath}
}
$hashes | ConvertTo-Json -Depth 4 | Set-Content reports/artifact-hashes.json
if($seen.Count -ne 4 -or $failed){throw 'PHP artifact QA failed'}
