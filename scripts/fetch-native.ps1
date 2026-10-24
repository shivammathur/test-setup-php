param([Parameter(Mandatory)][string]$LaneId,[Parameter(Mandatory)][string]$Phase)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$lane=@((Get-Content native-matrix.json -Raw | ConvertFrom-Json).include | Where-Object {$_.id -eq $LaneId})
if($lane.Count -ne 1){throw 'Ambiguous native lane'}
$lane=$lane[0]
New-Item reports,packages,deps,build -ItemType Directory -Force | Out-Null
$expected=Get-Content expected-hashes.json -Raw | ConvertFrom-Json -AsHashtable
foreach($entry in $lane.dependencies.PSObject.Properties) {
  $file=$entry.Value
  $url="https://downloads.php.net/~windows/php-sdk/deps/$($lane.vs)/$($lane.arch)/$file"
  Invoke-WebRequest $url -OutFile "packages/$file"
  Expand-Archive "packages/$file" deps -Force
  "$url $((Get-FileHash "packages/$file" -Algorithm SHA256).Hash)" | Add-Content reports/unchanged-dependencies.txt
}
foreach($entry in $lane.libraries.PSObject.Properties) {
  $item=$entry.Value;$destination="packages/$($entry.Name)"
  New-Item $destination -ItemType Directory -Force | Out-Null
  if($Phase -eq 'candidate') {
    gh run download $item.run -R winlibs/winlib-builder -n $item.artifact -D $destination
    if($LASTEXITCODE){throw "Artifact download failed: $($item.artifact)"}
  } else {
    $base=if($item.type -eq 'pecl'){'https://downloads.php.net/~windows/pecl/deps'}else{"https://downloads.php.net/~windows/php-sdk/deps/$($lane.vs)/$($lane.arch)"}
    $url="$base/$($item.artifact).zip"
    Invoke-WebRequest $url -OutFile "$destination.zip"
    Expand-Archive "$destination.zip" $destination -Force
    "$url $((Get-FileHash "$destination.zip" -Algorithm SHA256).Hash)" | Add-Content reports/canonical-packages.txt
  }
  python scripts/verify-hashes.py --manifest expected-hashes.json --directory $destination --artifact $item.artifact --report "reports/$($entry.Name)-hashes.json"
  if($LASTEXITCODE){throw "Exact package verification failed: $($entry.Name)"}
  Copy-Item "$destination/*" deps -Recurse -Force
}
$env:PATH="$(Resolve-Path deps/bin);$env:PATH"
$lane | ConvertTo-Json -Depth 10 | Set-Content reports/lane.json
if($Phase -eq 'published' -and $lane.kind -eq 'graphics') {
  $resolver=(Resolve-Path winlib-builder/scripts/fetch-deps.ps1).Path
  New-Item resolver-check -ItemType Directory -Force | Out-Null
  Push-Location resolver-check
  try {
    & powershell.exe -NoProfile -File $resolver -lib librrd -version $lane.php -vs $lane.vs -arch $lane.arch -stability staging *>&1 | Tee-Object ../reports/published-resolver.log
    if($LASTEXITCODE){throw 'Published dependency resolution failed'}
    foreach($library in @('cairo','pango','glib','libpng','zlib')) {
      $item=$lane.libraries.$library;$manifest=$expected[$item.artifact]
      foreach($name in $manifest.Keys) {
        if($name -eq 'COPYING'){continue}
        $path=Join-Path deps $name
        if(!(Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest[$name]){throw "Published resolver mismatch: $library/$name"}
      }
    }
  } finally {Pop-Location}
}
