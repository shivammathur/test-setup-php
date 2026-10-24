param([string]$Vs,[string]$Arch)
$ErrorActionPreference='Stop'
# Apache's SDK ships vcpkg import libraries plus a real static zlib library.
# Use the matching upstream-compatible zlib header from the PHP dependency set;
# Apache's copied vcpkg dynamic zconf.h unconditionally declares DLL imports.
Expand-Archive "packages/brotli-1.2.1-$Vs-$Arch.zip" packages/published-brotli -Force
python scripts/verify-hashes.py --manifest expected-hashes.json --directory packages/published-brotli --artifact "brotli-1.2.1-$Vs-$Arch" --report reports/brotli-hashes.json
if($LASTEXITCODE){throw 'Published Brotli package differs from the accepted 1.2.1 build'}
& cl.exe /nologo /W4 /MD /Ipackages/zlib/include /Ipackages/apache/include/apache2_4 native/apache-compression-smoke.c /Fobuild/apache-compression.obj /Febuild/apache-compression.exe /link /LIBPATH:packages/apache/lib/apache2_4 zs.lib brotlidec.lib brotlienc.lib brotlicommon.lib
if($LASTEXITCODE){throw 'Apache packaged compression libraries failed to link'}
& build/apache-compression.exe | Tee-Object reports/apache-compression.txt
if($LASTEXITCODE){throw 'Apache packaged compression runtime failed'}
@{passed=$true;vs=$Vs;arch=$Arch;zlib='1.3.2-winlibs.1';brotli='1.2.1'} | ConvertTo-Json | Set-Content reports/apache-native.json
