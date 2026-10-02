param(
    [Parameter(Mandatory)][string]$Php,
    [Parameter(Mandatory)][string]$Arch
)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content native-manifest.json -Raw | ConvertFrom-Json
$rows = @($manifest.lanes | Where-Object { $_.php -eq $Php -and $_.arch -eq $Arch })
if ($rows.Count -ne 1) { throw 'Expected one native manifest lane' }
$row = $rows[0]
New-Item reports, native-inputs, native-bin -ItemType Directory -Force | Out-Null
Start-Transcript reports/native-transcript.txt
$headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json' }
$api = 'https://api.github.com/repos/winlibs/winlib-builder'
foreach ($package in $row.packages) {
    $metadata = Invoke-RestMethod "$api/actions/artifacts/$($package.artifactId)" -Headers $headers
    if ($metadata.workflow_run.id -ne $package.runId -or $metadata.name -ne $package.name -or $metadata.expired) {
        throw "Artifact identity mismatch for $($package.name)"
    }
    $zip = "native-inputs/$($package.library).zip"
    if ($manifest.phase -eq 'published') {
        if ($package.url -notmatch '^https://downloads\.php\.net/~windows/(?:pecl/deps|php-sdk/deps/vs\d+/(?:x64|x86))/[^/?]+\.zip$') {
            throw 'Expected a canonical published package URL'
        }
        $response = Invoke-WebRequest $package.url -OutFile $zip -PassThru
        @{ url=$package.url; headers=$response.Headers; observedAt=(Get-Date).ToUniversalTime().ToString('o') } |
            ConvertTo-Json -Depth 10 | Set-Content "reports/$($package.library)-publication.json"
    } else {
        Invoke-WebRequest "$api/actions/artifacts/$($package.artifactId)/zip" -Headers $headers -OutFile $zip
    }
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $package.sha256) {
        throw "Artifact hash mismatch for $($package.name)"
    }
    Expand-Archive $zip "native-inputs/$($package.library)"
}
$ssl = (Resolve-Path native-inputs/openssl).Path
$kafka = (Resolve-Path native-inputs/librdkafka).Path
$rabbit = (Resolve-Path native-inputs/librabbitmq).Path
$env:PATH = "$ssl\bin;$kafka\bin;$rabbit\bin;$env:PATH"
$env:OPENSSL_CONF = "$ssl\openssl.cnf"
$openssl = "$ssl\bin\openssl.exe"
$version = & $openssl version
if ($LASTEXITCODE -ne 0 -or $version -notmatch ('^OpenSSL ' + [regex]::Escape($row.opensslVersion) + '(?:\s|$)')) {
    throw "Unexpected native OpenSSL version: $version"
}
Get-ChildItem native-inputs -Recurse -File | Get-FileHash -Algorithm SHA256 |
    Select-Object Path, Hash | ConvertTo-Json | Set-Content reports/native-input-hashes.json
$failures = @()
& cl /nologo /W4 /MD /I"$kafka\include" tests/native-kafka-tls.c /Fenative-bin/kafka.exe /link /LIBPATH:"$kafka\lib" librdkafka.lib
if ($LASTEXITCODE -ne 0) { $failures += 'Kafka artifact link failed' }
& cl /nologo /W4 /MD /I"$rabbit\include" tests/native-rabbitmq-tls.c /Fenative-bin/rabbitmq-shared.exe /link /LIBPATH:"$rabbit\lib" rabbitmq.4.lib
if ($LASTEXITCODE -ne 0) { $failures += 'Shared RabbitMQ artifact link failed' }
& cl /nologo /W4 /MD /DAMQP_STATIC /I"$rabbit\include" tests/native-rabbitmq-tls.c /Fenative-bin/rabbitmq-static.exe /link /LIBPATH:"$rabbit\lib" /LIBPATH:"$ssl\lib" librabbitmq.4.lib libssl.lib libcrypto.lib ws2_32.lib crypt32.lib
if ($LASTEXITCODE -ne 0) { $failures += 'Static RabbitMQ artifact link failed' }
foreach ($client in @('kafka', 'rabbitmq-shared', 'rabbitmq-static')) {
    if (Test-Path "native-bin/$client.exe") {
        python tests/native-tls-server.py (Resolve-Path "native-bin/$client.exe").Path $openssl "reports/$client"
        if ($LASTEXITCODE -ne 0) { $failures += "$client TLS behavior failed" }
    }
}
$row | ConvertTo-Json -Depth 20 | Set-Content reports/native-manifest-lane.json
Stop-Transcript
if ($failures.Count) { throw ($failures -join '; ') }
