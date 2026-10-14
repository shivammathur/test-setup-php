param(
  [Parameter(Mandatory)][string] $Vs,
  [Parameter(Mandatory)][string] $Arch,
  [Parameter(Mandatory)][string] $Smb,
  [Parameter(Mandatory)][string] $Generator,
  [Parameter(Mandatory)][string] $MsArch,
  [Parameter(Mandatory)][string] $Toolset,
  [Parameter(Mandatory)][string] $Sdk
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force reports | Out-Null
$root = (Get-Location).Path
$env:PATH = "$root/deps/bin;$env:PATH"
Get-ChildItem candidate-curl,candidate-freetype -Recurse -File | ForEach-Object {
  @{file=[IO.Path]::GetRelativePath($root,$_.FullName);sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash}
} | ConvertTo-Json -Depth 4 | Set-Content reports/candidate-hashes.json
& ./candidate-curl/bin/curl.exe --version | Tee-Object reports/curl-version.txt
if ($LASTEXITCODE) { throw 'curl failed to start' }
python scripts/check-smb.py --curl "$root/candidate-curl/bin/curl.exe" --expect-smb $Smb --report reports/smb.json
if ($LASTEXITCODE) { throw 'Native SMB checks failed' }
$baseline = "https://downloads.php.net/~windows/php-sdk/deps/$Vs/$Arch/freetype-2.14.3-$Vs-$Arch.zip"
Invoke-WebRequest $baseline -OutFile baseline.zip
@{url=$baseline;sha256=(Get-FileHash baseline.zip -Algorithm SHA256).Hash} | ConvertTo-Json | Set-Content reports/baseline.json
Expand-Archive baseline.zip baseline -Force
python scripts/make-fonts.py reports/composite32764.ttf reports/composite32765.ttf reports/composite32766.ttf reports/composite32767.ttf
if ($LASTEXITCODE) { throw 'Font generation failed' }
foreach ($variant in @('candidate','baseline')) {
  $ft = if ($variant -eq 'candidate') { "$root/candidate-freetype" } else { "$root/baseline" }
  $version = if ($variant -eq 'candidate') { '2.15.0' } else { '2.14.3' }
  cmake -S native -B "build-$variant" -G "Visual Studio $Generator" -A $MsArch -T $Toolset "-DCMAKE_SYSTEM_VERSION=$Sdk" "-DFREETYPE_ROOT=$ft"
  if ($LASTEXITCODE) { throw "Configure $variant failed" }
  cmake --build "build-$variant" --config Release
  if ($LASTEXITCODE) { throw "Compile $variant failed" }
  & "./build-$variant/Release/freetype-probe.exe" "reports/$variant.csv" 'reports/composite32764.ttf' $version | Tee-Object "reports/$variant.txt"
  if ($LASTEXITCODE) { throw "FreeType $variant regression probe failed: $LASTEXITCODE" }
}
python scripts/compare-freetype.py reports/baseline.csv reports/candidate.csv reports/freetype-comparison.json
if ($LASTEXITCODE) { throw 'FreeType comparison failed' }
