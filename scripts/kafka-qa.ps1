$ErrorActionPreference='Stop'
& cl.exe /nologo /W3 /MD /O2 /Ideps/include native/kafka-gzip.c /Febuild/kafka-gzip.exe /link /LIBPATH:deps/lib librdkafka.lib
if($LASTEXITCODE){throw 'Kafka gzip client compilation failed'}
& build/kafka-gzip.exe *>&1 | Tee-Object reports/kafka-gzip.log
if($LASTEXITCODE){throw 'Kafka mock-cluster gzip round trip failed'}
dumpbin /nologo /dependents deps/bin/librdkafka.dll > reports/kafka-imports.txt
if($LASTEXITCODE){throw 'Kafka DLL inspection failed'}
@{passed=$true;messages=32;compression='gzip'} | ConvertTo-Json | Set-Content reports/kafka-native.json
