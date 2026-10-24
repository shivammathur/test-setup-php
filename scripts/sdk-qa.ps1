param([string]$Vs,[string]$Arch)
$ErrorActionPreference='Stop'
& cl.exe /nologo /W3 /O2 /MD /I deps/include native/zlib-probe.c /Febuild/zlib-probe.exe /link /LIBPATH:deps/lib zlib_a.lib
if($LASTEXITCODE){throw 'Zlib static probe compilation failed'}
& build/zlib-probe.exe | Tee-Object reports/zlib-native.txt
if($LASTEXITCODE){throw 'Zlib static probe failed'}
foreach($variant in @('shared','static')) {
  $options=if($variant -eq 'static'){@('/DPNG_STATIC')}else{@()}
  $libs=if($variant -eq 'static'){@('libpng_a.lib','zlib_a.lib')}else{@('libpng.lib')}
  & cl.exe /nologo /W3 /O2 /MD @options /Ideps/include/libpng16 tests/png-roundtrip.c "/Febuild/png-$variant.exe" /link /LIBPATH:deps/lib @libs
  if($LASTEXITCODE){throw "PNG $variant compilation failed"}
  & "build/png-$variant.exe" | Tee-Object "reports/png-$variant.txt"
  if($LASTEXITCODE){throw "PNG $variant round trips failed"}
}
Copy-Item packages/libzip candidate-libzip -Recurse -Force
./scripts/libzip-native-qa.ps1 -Vs $Vs -Arch $Arch
if($LASTEXITCODE){throw 'Libzip static QA failed'}
& cl.exe /nologo /W3 /O2 /MD /Ideps/include/glib-2.0 /Ideps/lib/glib-2.0/include native/glib-gio-probe.c /Febuild/glib-gio-probe.exe /link /LIBPATH:deps/lib glib-2.0.lib gio-2.0.lib gobject-2.0.lib
if($LASTEXITCODE){throw 'GLib GIO probe compilation failed'}
& build/glib-gio-probe.exe | Tee-Object reports/glib-gio-native.txt
if($LASTEXITCODE){throw 'GLib GIO probe failed'}
python tests/enchant-runtime.py
if($LASTEXITCODE){throw 'Enchant integration failed'}
@{passed=$true;vs=$Vs;arch=$Arch;probes=@('zlib','png-shared','png-static','libzip','glib-gio','enchant')} | ConvertTo-Json | Set-Content reports/sdk-native.json
