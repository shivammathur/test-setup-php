param([string]$Vs,[string]$Arch)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force reports | Out-Null
python scripts/verify-hashes.py --manifest expected-hashes.json --directory candidate-libzip --artifact "libzip-1.12.1-$Vs-$Arch" --report reports/libzip-hashes.json
if($LASTEXITCODE){throw 'Libzip artifact mismatch'}
[string[]]$timeDefine=if($Arch -eq 'x86'){@('/D_USE_32BIT_TIME_T=1')}else{@()}
$libraries=@('candidate-libzip/lib/libzip_a.lib','deps/lib/libbz2_a.lib','deps/lib/zlib_a.lib','deps/lib/liblzma_a.lib','bcrypt.lib','advapi32.lib')
$cases=@()
foreach($probe in @('check-libzip','filep_error')) {
  & cl.exe /nologo /W4 /WX /MD /O2 /DZIP_STATIC /D_CRT_SECURE_NO_WARNINGS /Icandidate-libzip/include @timeDefine "native/$probe.c" "/Fe:$probe.exe" /link @libraries
  if($LASTEXITCODE){throw "Compile $probe failed"}
  [string[]]$arguments=if($probe -eq 'filep_error'){@('native/filep-input.txt')}else{@()}
  $output=& "./$probe.exe" @arguments 2>&1
  $code=$LASTEXITCODE
  $output | Set-Content "reports/$probe.txt"
  if($code -ne 0){throw "$probe failed: $code"}
  if($probe -eq 'check-libzip') {
    if(($output -join "`n") -notmatch '^libzip 1\.12\.1' -or @($output | Where-Object {$_ -match 'method .*: passed'}).Count -ne 12 -or ($output -join "`n") -notmatch 'torrentzip add/replace round trips: passed'){throw 'Missing compression, crypto or TorrentZip checks'}
  } elseif(($output -join "`n").Trim() -ne "Invalid argument`nclosed") {throw 'File stream ownership regression output differs'}
  $imports=& dumpbin /dependents "$probe.exe"
  if($LASTEXITCODE){throw 'dumpbin failed'}
  $imports | Set-Content "reports/$probe-imports.txt"
  if(($imports -join "`n") -match '(?i)(zip|zstd|zlib|bz2|lzma).*\.dll'){throw 'Unexpected dynamic compression dependency'}
  $cases+=@{probe=$probe;passed=$true;sha256=(Get-FileHash "$probe.exe" -Algorithm SHA256).Hash}
}
@{vs=$Vs;arch=$Arch;checks=14;cases=$cases;passed=$true} | ConvertTo-Json -Depth 5 | Set-Content reports/libzip-native.json
