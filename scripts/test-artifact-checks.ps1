Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. "$PSScriptRoot/artifact-checks.ps1"
$script:checks=0
function Must-Reject([scriptblock]$Operation){$rejected=$false;try{& $Operation}catch{$rejected=$true};if(!$rejected){throw 'Failure gate accepted bad input'};$script:checks++}
$v=Get-Variant 'php-8.2.36-dev-Win32-vs16-x64.zip'
Assert-Equal $true $v.Zts 'TS parsed'
Assert-Equal $false (Get-Variant 'php-8.2.36-dev-nts-Win32-vs16-x86.zip').Zts 'NTS parsed'
Must-Reject {Get-Variant 'php-debug-pack-8.2.36-dev-Win32-vs16-x64.zip'}
Must-Reject {Get-Variant 'php-8.2.36-dev-Win32-vs16-arm64.zip'}
$r=[pscustomobject]@{failures=0;php='8.2.36-dev';os='Windows';bits=64;zts=$true;opcache='0';sqlite=@{versionString='3.54.1'};tests=300;assertions=1500;results=@()}
$names=@('coverage/public-api-inventory','sqlite3/coverage/sql-functions','sqlite3/coverage/virtual-table-modules','pdo/coverage/sql-functions','pdo/coverage/virtual-table-modules')+@(1..295 | ForEach-Object {"case-$_"})
$r.results=@($names | ForEach-Object {[pscustomobject]@{name=$_;status='pass';assertions=5}})
Assert-Report $r $v 0
$r.failures=1;Must-Reject {Assert-Report $r $v 0};$r.failures=0
$r.sqlite.versionString='3.53.0';Must-Reject {Assert-Report $r $v 0};$r.sqlite.versionString='3.54.1'
$r.bits=32;Must-Reject {Assert-Report $r $v 0};$r.bits=64
$r.results[0].name='missing-gate';Must-Reject {Assert-Report $r $v 0};$r.results[0].name='coverage/public-api-inventory'
$r.results[0].status='fail';Must-Reject {Assert-Report $r $v 0};$r.results[0].status='pass'
$r.tests=0;Must-Reject {Assert-Report $r $v 0};$r.tests=300
$r.assertions=0;Must-Reject {Assert-Report $r $v 0};$r.assertions=1500
Must-Reject {Assert-Report $r $v 1}
$temp=New-TemporaryFile
try{Set-Content $temp 'fixture';$hash=(Get-FileHash $temp -Algorithm SHA256).Hash;Assert-Hash $temp $hash;Must-Reject {Assert-Hash $temp ('0'*64)};Must-Reject {Assert-Pe $temp 'x64'}}finally{Remove-Item $temp}
$root=Split-Path $PSScriptRoot
$m=Get-Content "$root/artifacts.json" -Raw | ConvertFrom-Json
Assert-Equal 6 @($m.builds).Count 'source build count'
$yaml=Get-Content "$root/.github/workflows/sqlite-userland.yml" -Raw
foreach($b in $m.builds){if(!$yaml.Contains("target: $($b.ref), run: '$($b.run)', runner: $($b.runner)")){throw "Matrix differs from manifest for $($b.ref)"}}
Write-Host "PASS runner self-test: $script:checks rejection checks, valid report and six manifest/matrix mappings"
