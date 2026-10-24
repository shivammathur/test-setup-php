$ErrorActionPreference='Stop'
foreach($variant in @('shared','static')) {
  $options=if($variant -eq 'static'){@('/DPNG_STATIC')}else{@()}
  $libs=if($variant -eq 'static'){@('libpng_a.lib','zlib_a.lib')}else{@('libpng.lib')}
  & cl.exe /nologo /W3 /O2 /MD @options /Ideps/include/libpng16 tests/png-roundtrip.c "/Febuild/png-$variant.exe" /link /LIBPATH:deps/lib @libs
  if($LASTEXITCODE){throw "PNG $variant compilation failed"}
  & "build/png-$variant.exe" | Tee-Object "reports/png-$variant.txt"
  if($LASTEXITCODE){throw "PNG $variant test failed"}
}
python tests/consumer-runtime.py | Tee-Object reports/consumer-runtime.log
if($LASTEXITCODE){throw 'Cairo/Pango/RRD runtime checks failed'}
foreach($dll in @('libpng.dll','cairo-2.dll','pango-1.0-0.dll','pangocairo-1.0-0.dll','librrd-8.dll')) {
  dumpbin /nologo /headers /dependents /exports "deps/bin/$dll" > "reports/$dll-dumpbin.txt"
  if($LASTEXITCODE){throw 'PE inspection failed'}
}
