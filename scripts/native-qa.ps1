param([string]$Php,[string]$Arch,[string]$Vs,[string]$Generator,[string]$MsArch,[string]$Toolset,[string]$Sdk)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force reports | Out-Null
$root=(Get-Location).Path
$env:PATH="$root/candidate-brotli/bin;$root/candidate-jxl/bin;$root/deps/bin;$env:PATH"
python scripts/verify-hashes.py --manifest expected-hashes.json --directory candidate-brotli --artifact "brotli-1.2.1-$Vs-$Arch" --report reports/brotli-hashes.json
if($LASTEXITCODE){throw 'Brotli artifact mismatch'}
$suffix=if($Php -in '8.2','8.4'){'1'}else{'2'}
python scripts/verify-hashes.py --manifest expected-hashes.json --directory candidate-curl --artifact "libcurl-8.23.0-$suffix-$Vs-$Arch" --report reports/curl-hashes.json
if($LASTEXITCODE){throw 'curl artifact mismatch'}
if($Php -eq '8.6') {
python scripts/verify-hashes.py --manifest expected-hashes.json --directory candidate-jxl --artifact "libjxl-0.12.0-$Vs-$Arch" --report reports/jxl-hashes.json
if($LASTEXITCODE){throw 'libjxl artifact mismatch'}
}
$jxlRoot=if($Php -eq '8.6'){"$root/candidate-jxl"}else{''}
cmake -S native -B build -G "Visual Studio $Generator" -A $MsArch -T $Toolset "-DCMAKE_SYSTEM_VERSION=$Sdk" "-DBROTLI_ROOT=$root/candidate-brotli" "-DJXL_ROOT=$jxlRoot"
if($LASTEXITCODE){throw 'Configure native probes failed'}
cmake --build build --config RelWithDebInfo
if($LASTEXITCODE){throw 'Compile native probes failed'}
$probes=@('brotli-probe'); if($Php -eq '8.6'){$probes+=@('jxl-shared-probe','jxl-static-probe')}
foreach($probe in $probes) {
  & "./build/RelWithDebInfo/$probe.exe" | Tee-Object "reports/$probe.json"
  if($LASTEXITCODE){throw "$probe failed"}
}
& ./candidate-curl/bin/curl.exe --version | Tee-Object reports/curl-version.txt
if($LASTEXITCODE){throw 'curl executable failed'}
python scripts/http-qa.py --curl "$root/candidate-curl/bin/curl.exe" --fixtures reports --report reports/curl-http.json
if($LASTEXITCODE){throw 'curl HTTP Brotli integration failed'}
python scripts/corpus-qa.py --brotli "$root/candidate-brotli/bin/brotli.exe" --corpus upstream-brotli/tests/testdata --report reports/corpus.json
if($LASTEXITCODE){throw 'Brotli upstream corpus failed'}
dumpbin /dependents candidate-curl/bin/curl.exe | Out-File reports/curl-imports.txt
if($Php -eq '8.6'){dumpbin /dependents candidate-jxl/bin/jxl.dll | Out-File reports/jxl-imports.txt}
