param([Parameter(Mandatory)] [string] $Branch, [switch] $Regressions)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = (Get-Location).Path
$manifest = Get-Content manifest.json -Raw | ConvertFrom-Json -AsHashtable
$entry = $manifest.branches[$Branch]
$reportRoot = Join-Path $root 'reports'
New-Item $reportRoot -ItemType Directory -Force | Out-Null
$cases = [Collections.Generic.List[object]]::new()
$hashes = [Collections.Generic.List[object]]::new()
function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ($Actual -ne $Expected) { throw "${Message}: expected '$Expected', got '$Actual'" }
}
function Get-Sha([byte[]] $Bytes) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Read-Http([Net.Http.HttpClient] $Client, [string] $Url, [string] $Encoding = 'identity', [byte[]] $Body = $null) {
    $request = [Net.Http.HttpRequestMessage]::new($(if ($null -eq $Body) { [Net.Http.HttpMethod]::Get } else { [Net.Http.HttpMethod]::Post }), $Url)
    $request.Headers.AcceptEncoding.ParseAdd($Encoding)
    if ($null -ne $Body) {
        $request.Content = [Net.Http.ByteArrayContent]::new($Body)
        $request.Content.Headers.ContentEncoding.Add('gzip')
    }
    $response = $null
    try {
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode): $([Text.Encoding]::UTF8.GetString($bytes))" }
        return @{ bytes=$bytes; encoding=($response.Content.Headers.ContentEncoding -join ',') }
    } finally { if ($response) { $response.Dispose() }; $request.Dispose() }
}
function Decode-Body([byte[]] $Bytes, [string] $Encoding) {
    $inputStream = [IO.MemoryStream]::new($Bytes)
    $outputStream = [IO.MemoryStream]::new()
    $decoder = if ($Encoding -eq 'gzip') { [IO.Compression.GZipStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress) } else { [IO.Compression.BrotliStream]::new($inputStream, [IO.Compression.CompressionMode]::Decompress) }
    try { $decoder.CopyTo($outputStream); return ,$outputStream.ToArray() }
    finally { $decoder.Dispose(); $inputStream.Dispose(); $outputStream.Dispose() }
}
$runtimeZips = @(Get-ChildItem artifacts -Filter 'php-*.zip' -File | Where-Object { $_.Name -match '^php-(?!debug-pack-|devel-pack-|test-pack-).+?-(?:nts-)?Win32-v[sc]\d+-(x64|x86)\.zip$' })
Assert-Equal $runtimeZips.Count 4 'PHP runtime archive count'
foreach ($arch in 'x64', 'x86') {
    foreach ($file in $manifest.apache[$arch].files.GetEnumerator()) {
        $path = Join-Path "$root/apache/$arch" $file.Key
        Assert-Equal (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() $file.Value "Apache file hash $arch/$($file.Key)"
    }
}
foreach ($zip in $runtimeZips) {
    $expected = $entry.php[$zip.Name]
    if (-not $expected) { throw "Unrecognized runtime archive: $($zip.Name)" }
    $sha = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $sha $expected.sha256 'PHP artifact hash'
    $hashes.Add(@{ file=$zip.Name; sha256=$sha; sourceRun=$entry.run })
    $arch = $expected.arch; $ts = $expected.ts
    $phpRoot = Join-Path $env:RUNNER_TEMP "apache-php/$Branch/$arch-$ts"
    Expand-Archive $zip.FullName $phpRoot -Force
    $php = Join-Path $phpRoot 'php.exe'
    $cli = (& $php -n -r 'echo json_encode(["version"=>PHP_VERSION,"zts"=>PHP_ZTS,"bits"=>PHP_INT_SIZE*8]);') | ConvertFrom-Json
    Assert-Equal $cli.zts $(if ($ts -eq 'ts') { 1 } else { 0 }) 'PHP thread safety'
    Assert-Equal $cli.bits $(if ($arch -eq 'x64') { 64 } else { 32 }) 'PHP architecture'
    $apache = (Resolve-Path "apache/$arch").Path.Replace('\', '/')
    $phpPath = $phpRoot.Replace('\', '/')
    $httpd = "$apache/bin/httpd.exe"
    foreach ($cache in 'nocache', 'opcache') {
        $label = "$arch-$ts-$cache"
        $report = Join-Path $reportRoot $label
        New-Item $report -ItemType Directory -Force | Out-Null
        $document = (Join-Path $report 'htdocs').Replace('\', '/')
        New-Item $document -ItemType Directory -Force | Out-Null
        Copy-Item tests/endpoint.php "$document/index.php"
        if ($Regressions) { Copy-Item tests/regressions.php "$document/regressions.php"; Copy-Item tests/record-errors.php "$document/record-errors.php" }
        $payload = [Text.Encoding]::UTF8.GetBytes(('Apache and PHP compression integration.' * 4096))
        [IO.File]::WriteAllBytes("$document/payload.txt", $payload)
        $payloadSha = Get-Sha $payload
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
        $url = "http://127.0.0.1:$port/index.php"
        $config = (Join-Path $report 'httpd.conf').Replace('\', '/')
        $logPath = $report.Replace('\', '/')
        $ini = @('[PHP]', "extension_dir=`"$phpPath/ext`"", 'extension=curl', 'display_errors=0', 'display_startup_errors=0', 'log_errors=1', 'error_reporting=-1', "error_log=`"$logPath/php-errors.log`"", 'date.timezone=UTC', 'cgi.force_redirect=0', 'cgi.fix_pathinfo=1', "session.save_path=`"$logPath`"")
        if ($Regressions) { $ini += @('extension=intl', 'session.use_trans_sid=1', 'opcache.record_warnings=1') }
        $enabled = if ($cache -eq 'opcache') { 1 } else { 0 }
        $ini += @("opcache.enable=$enabled", "opcache.enable_cli=$enabled")
        if ($enabled -and (Test-Path "$phpRoot/ext/php_opcache.dll")) { $ini += 'zend_extension=opcache' }
        $ini | Set-Content "$phpRoot/php.ini"
        $handlerConfig = if ($ts -eq 'ts') {
            "LoadModule php_module `"$phpPath/php8apache2_4.dll`"`nPHPIniDir `"$phpPath`""
        } else {
            @"
LoadModule actions_module modules/mod_actions.so
LoadModule cgi_module modules/mod_cgi.so
ScriptAlias /php-cgi/ "$phpPath/"
Action application/x-httpd-php /php-cgi/php-cgi.exe
SetEnv PHPRC "$phpPath"
<Directory "$phpPath">
    Options +ExecCGI
    Require all granted
</Directory>
"@
        }
        @"
ServerRoot "$apache"
ServerName 127.0.0.1
Listen 127.0.0.1:$port
ThreadsPerChild $(if ($Regressions) { 250 } else { 16 })
$(if ($Regressions) { "AddDefaultCharset UTF-8" })
PidFile "$logPath/httpd.pid"
ErrorLog "$logPath/apache-errors.log"
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule alias_module modules/mod_alias.so
LoadModule env_module modules/mod_env.so
LoadModule filter_module modules/mod_filter.so
LoadModule deflate_module modules/mod_deflate.so
LoadModule brotli_module modules/mod_brotli.so
$handlerConfig
SetOutputFilter BROTLI_COMPRESS;DEFLATE
DocumentRoot "$document"
<Directory "$document">
    Require all granted
    <FilesMatch \.php$>
        SetHandler application/x-httpd-php
    </FilesMatch>
</Directory>
"@ | Set-Content $config
        $originalPath = $env:PATH
        $caseStarted = Get-Date
        $server = $null; $client = $null
        $result = @{ label=$label; passed=$false; phpArchive=$zip.Name; phpSha256=$sha; checks=@() }
        try {
            $env:PATH = "$apache/bin;$phpRoot;$originalPath"
            & $httpd -v *> "$report/apache-version.txt"
            & $httpd -t -f $config *> "$report/config-check.txt"
            $server = Start-Process $httpd -ArgumentList @('-X','-f',"`"$config`"") -PassThru -RedirectStandardOutput "$report/stdout.log" -RedirectStandardError "$report/stderr.log"
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
            $handler.UseProxy = $false
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(30)
            $ready = $false
            for ($attempt=0; $attempt -lt 30; $attempt++) {
                $server.Refresh()
                if ($server.HasExited) { throw "Apache exited: $($server.ExitCode)" }
                try { $null = Read-Http $client "http://127.0.0.1:$port/payload.txt"; $ready=$true; break }
                catch { Start-Sleep -Milliseconds 500 }
            }
            if (-not $ready) { throw 'Apache did not become ready' }
            $info = [Text.Encoding]::UTF8.GetString((Read-Http $client $url).bytes) | ConvertFrom-Json
            $result.info = $info
            Assert-Equal $info.php $cli.version 'Apache served the selected PHP runtime'
            Assert-Equal $info.zts $cli.zts 'Apache PHP thread safety'
            Assert-Equal $info.bits $cli.bits 'Apache PHP architecture'
            Assert-Equal $info.sapi $(if ($ts -eq 'ts') {'apache2handler'} else {'cgi-fcgi'}) 'PHP SAPI'
            Assert-Equal $info.zlib $manifest.versions.zlib 'PHP zlib version'
            Assert-Equal $info.curl_zlib $manifest.versions.zlib 'PHP cURL zlib version'
            if ($info.apache -notmatch "Apache/$([regex]::Escape($manifest.versions.apache))(?:\s|$)") { throw "Wrong Apache version: $($info.apache)" }
            Assert-Equal $info.opcache_enabled ($cache -eq 'opcache') 'OPcache state'
            Assert-Equal $info.sha256 $payloadSha 'PHP payload hash'
            $result.checks += 'PHP identity/SAPI/version; zlib compression; cURL identity/gzip/br'
            foreach ($encoding in 'identity', 'gzip', 'br') {
                $response = Read-Http $client "$url`?mode=payload" $encoding
                if ($encoding -eq 'identity') { Assert-Equal $response.encoding '' 'Identity encoding'; $decoded=$response.bytes }
                else {
                    Assert-Equal $response.encoding $encoding 'Apache compression encoding'
                    if ($response.bytes.Length -ge $payload.Length) { throw 'Response did not compress' }
                    $decoded = Decode-Body $response.bytes $encoding
                }
                Assert-Equal (Get-Sha $decoded) $payloadSha "Apache/PHP $encoding round trip"
                $result.checks += "Apache/PHP $encoding response"
            }
            $compressed = Read-Http $client "$url`?mode=php-gzip" 'gzip'
            Assert-Equal $compressed.encoding 'gzip' 'PHP gzip encoding'
            Assert-Equal (Get-Sha (Decode-Body $compressed.bytes 'gzip')) $payloadSha 'PHP gzip response'
            $post = [Text.Encoding]::UTF8.GetString((Read-Http $client "$url`?mode=post" 'identity' $compressed.bytes).bytes) | ConvertFrom-Json
            Assert-Equal $post.sha256 $payloadSha 'Compressed POST body'
            $result.checks += 'PHP gzip response; compressed POST'
            $session1 = [Text.Encoding]::UTF8.GetString((Read-Http $client "$url`?mode=session").bytes) | ConvertFrom-Json
            $session2 = [Text.Encoding]::UTF8.GetString((Read-Http $client "$url`?mode=session").bytes) | ConvertFrom-Json
            Assert-Equal $session2.id $session1.id 'Session cookie persistence'; Assert-Equal $session2.count 2 'Session counter'
            $result.checks += 'PHP session persistence'
            for ($repeat=0; $repeat -lt 10; $repeat++) {
                Assert-Equal (Get-Sha (Read-Http $client "$url`?mode=payload").bytes) $payloadSha 'Repeated PHP requests'
            }
            $server.Refresh()
            $modules = @($server.Modules | ForEach-Object { @{ name=$_.ModuleName; file=$_.FileName } })
            $modules | ConvertTo-Json -Depth 4 | Set-Content "$report/loaded-modules.json"
            foreach ($relative in $manifest.apache[$arch].verifyModules) {
                $name = [IO.Path]::GetFileName($relative)
                $loaded = @($modules | Where-Object { $_.name -ieq $name })
                Assert-Equal $loaded.Count 1 "Loaded Apache module count: $name"
                Assert-Equal (Get-FileHash $loaded[0].file -Algorithm SHA256).Hash.ToLowerInvariant() $manifest.apache[$arch].files[$relative] "Loaded Apache module hash: $name"
            }
            if ($ts -eq 'ts') {
                $loadedPhp = @($modules | Where-Object { $_.name -ieq 'php8apache2_4.dll' })
                Assert-Equal $loadedPhp.Count 1 'Loaded PHP Apache module count'
                Assert-Equal (Get-FileHash $loadedPhp[0].file -Algorithm SHA256).Hash (Get-FileHash "$phpRoot/php8apache2_4.dll" -Algorithm SHA256).Hash 'Loaded PHP Apache module hash'
            }
            if ($Regressions) {
                $regressionUrl = "http://127.0.0.1:$port/regressions.php"
                $generations = [Collections.Generic.List[object]]::new()
                for ($generation=0; $generation -lt 3; $generation++) {
                    if ($generation -gt 0) {
                        Stop-Process -Id $server.Id -Force
                        $server.WaitForExit(); $server.Dispose()
                        Remove-Item "$report/httpd.pid" -ErrorAction SilentlyContinue
                        $server = Start-Process $httpd -ArgumentList @('-X','-f',"`"$config`"") -PassThru -RedirectStandardOutput "$report/stdout-$generation.log" -RedirectStandardError "$report/stderr-$generation.log"
                        $ready = $false
                        for ($attempt=0; $attempt -lt 30; $attempt++) {
                            $server.Refresh()
                            if ($server.HasExited) { throw "Apache generation $generation exited: $($server.ExitCode)" }
                            try { $null = Read-Http $client "http://127.0.0.1:$port/payload.txt"; $ready=$true; break }
                            catch { Start-Sleep -Milliseconds 500 }
                        }
                        if (-not $ready) { throw 'Restarted Apache did not become ready' }
                    }
                    $requests = 0
                    for ($batch=0; $batch -lt 4; $batch++) {
                        $tasks = @(1..64 | ForEach-Object { $client.GetAsync("$regressionUrl`?request=$generation-$batch-$_") })
                        [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]$tasks).GetAwaiter().GetResult()
                        foreach ($task in $tasks) {
                            $response = $task.GetAwaiter().GetResult()
                            try {
                                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                                Assert-Equal ([int]$response.StatusCode) 200 "Regression response: $body"
                                $data = $body | ConvertFrom-Json
                                Assert-Equal $data.passed $true 'Regression endpoint checks'
                                Assert-Equal $data.php $cli.version 'Regression PHP version'
                                Assert-Equal $data.trans_sid '1' 'Startup deprecation trigger enabled'
                                if ($ts -eq 'ts') { Assert-Equal $data.pid $server.Id 'Stable Apache process' }
                                $requests++
                            } finally { $response.Dispose() }
                        }
                    }
                    $server.Refresh()
                    if ($server.HasExited) { throw "Apache crashed after regression load: $($server.ExitCode)" }
                    $generations.Add(@{ generation=$generation; pid=$server.Id; requests=$requests; sample=$data })
                }
                $result.regressions = @{ generations=$generations.ToArray(); requests=768; concurrentRequests=64; coldStarts=3; phpDirectoryOnPath=$true; loadFileDirectives=$false }
                $result.checks += 'GH-22023 startup settings with concurrent sessions; curl/intl with standard PHP PATH and no LoadFile; GH-16900 date formatter; NTLM build feature'
            }
            if (Test-Path "$report/php-errors.log") {
                $errors = Get-Content "$report/php-errors.log" -Raw
                $unexpected = @(if ($Regressions) { @($errors -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch 'PHP Deprecated:.*session\.use_trans_sid.*deprecated.*Unknown on line 0' }) } else { @($errors -split "`n" | Where-Object { $_.Trim() }) })
                if ($unexpected.Count) { throw "PHP logged unexpected errors: $($unexpected -join [Environment]::NewLine)" }
                $result.expectedStartupDeprecations = @($errors -split "`n" | Where-Object { $_ -match 'PHP Deprecated:.*session\.use_trans_sid.*deprecated' }).Count
            }
            $result.checks += 'Repeated requests; exact loaded Apache/PHP modules; no unexpected PHP errors'
            if (Test-Path "$report/apache-errors.log") {
                $apacheErrors = Get-Content "$report/apache-errors.log" -Raw
                if ($apacheErrors -match '(?i)access violation|3221225477|segmentation fault|\[(?:[^\]]*:)?(?:error|crit|alert|emerg)\]') { throw "Apache logged errors: $apacheErrors" }
            }
            $result.passed = $true
            Write-Host "PASS $Branch $label"
        } catch {
            $result.error = $_.Exception.Message
            $_ | Out-String | Set-Content "$report/failure.txt"
            Write-Host "::error::$Branch $label $($_.Exception.Message)"
        } finally {
            if ($client) { $client.Dispose() }
            if ($server) { $server.Refresh(); if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }; $server.Dispose() }
            if ($Regressions) {
                Get-WinEvent -FilterHashtable @{ LogName='Application'; Id=1000,1001; StartTime=$caseStarted } -ErrorAction SilentlyContinue |
                    Where-Object { $_.Message -match 'php-cgi\.exe|httpd\.exe|php8(?:ts)?\.dll' } |
                    Select-Object TimeCreated, Id, Message | ConvertTo-Json -Depth 5 | Set-Content "$report/windows-crashes.json"
            }
            $env:PATH = $originalPath
            $result | ConvertTo-Json -Depth 10 | Set-Content "$report/result.json"
            $cases.Add($result)
        }
    }
}
$serverArchives = @($manifest.apache.GetEnumerator() | ForEach-Object { @{ arch=$_.Key; url=$_.Value.url; sha256=$_.Value.sha256; sha512=$_.Value.sha512 } })
$summary = @{ branch=$Branch; sourceSha=$entry.sourceSha; phpRun=$entry.run; apacheSdkRun=$entry.apacheRun; apacheProvider='Apache Lounge'; apacheArchives=$serverArchives; archives=$hashes.ToArray(); cases=$cases.ToArray(); passed=@($cases | Where-Object { $_.passed }).Count }
$summary | ConvertTo-Json -Depth 12 | Set-Content "$reportRoot/summary.json"
if ($cases.Count -ne 8 -or $summary.passed -ne 8) { throw "Passed $($summary.passed)/8 Apache/PHP integration cases" }
