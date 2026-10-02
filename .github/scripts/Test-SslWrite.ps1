param([ValidateSet('4.0.2','4.0.3')][string]$OpenSsl, [ValidateSet('write','psk')][string]$Kind = 'write')
$ErrorActionPreference = 'Stop'
$row = Get-Content ssl-write-manifest.json -Raw | ConvertFrom-Json
if ($Kind -eq 'psk') { $row = $row.psk }
$runtime = @($row.runtimeZips | Where-Object { $_.arch -eq 'x86' -and $_.ts -eq 'nts' })[0]
$package = @($row.packages | Where-Object version -EQ $OpenSsl)[0]
New-Item reports, unpacked, sources, cases, empty-ini -ItemType Directory -Force | Out-Null
$workspace = (Get-Location).Path
Start-Transcript reports/transcript.txt
$headers = @{Authorization="Bearer $env:GH_TOKEN"; Accept='application/vnd.github+json'}
$api = 'https://api.github.com/repos/shivammathur/php-windows-builder'
$artifact = Invoke-RestMethod "$api/actions/artifacts/$($row.artifactId)" -Headers $headers
if ($artifact.expired -or $artifact.workflow_run.id -ne $row.runId -or $artifact.name -ne 'artifacts') { throw 'Artifact identity changed' }
Invoke-WebRequest "$api/actions/artifacts/$($row.artifactId)/zip" -Headers $headers -OutFile merged.zip
if ((Get-FileHash merged.zip).Hash.ToLowerInvariant() -ne $row.artifactSha256) { throw 'Artifact digest changed' }
Expand-Archive merged.zip unpacked
$zip = Join-Path unpacked $runtime.name
if ((Get-FileHash $zip).Hash.ToLowerInvariant() -ne $runtime.sha256) { throw 'Runtime digest changed' }
Expand-Archive $zip runtime
Invoke-WebRequest $package.url -OutFile openssl.zip
if ((Get-FileHash openssl.zip).Hash.ToLowerInvariant() -ne $package.sha256) { throw 'OpenSSL package digest changed' }
Expand-Archive openssl.zip openssl
Get-ChildItem openssl/bin -Filter '*.dll' | Copy-Item -Destination runtime -Force
Copy-Item openssl/lib/ossl-modules/legacy.dll runtime/extras/ssl/legacy.dll -Force
$files = @(Get-ChildItem runtime -File | Where-Object Name -Match '^(php|lib(?:crypto|ssl)-)' | ForEach-Object { @{name=$_.Name; sha256=(Get-FileHash $_.FullName).Hash.ToLowerInvariant()} })
# Match the source job's complete extension configuration, including child processes.
$ini = @((Get-Content builder/php/BuildPhp/config/ini/ext.ini -Raw), "extension_dir=$workspace\runtime\ext")
if ($Kind -eq 'psk') {
    $opcache = Get-Content builder/php/BuildPhp/config/ini/opcache-ext-x86.ini -Raw
    $ini += $opcache.Replace('OPCACHE_ERROR_LOG_PATH', "$workspace\reports\opcache-error.log")
}
$ini | Set-Content runtime/php.ini
Copy-Item runtime/php.ini reports/test-configuration.ini
$env:PHPRC = (Resolve-Path runtime).Path
$env:PHP_INI_SCAN_DIR = (Resolve-Path empty-ini).Path
$env:OPENSSL_CONF = Join-Path $workspace 'runtime/extras/ssl/openssl.cnf'
$exe = (Resolve-Path runtime/php.exe).Path
$env:TEST_PHP_EXECUTABLE = $exe
# run-tests.php splits TEST_PHP_ARGS on spaces without parsing quotes. Supply
# the INI path only through the actual argument vector below.
Remove-Item Env:TEST_PHP_ARGS -ErrorAction SilentlyContinue
$env:NO_INTERACTION = '1'
$env:REPORT_EXIT_STATUS = '1'
$env:SKIP_ONLINE_TESTS = '1'
foreach ($source in $row.sources) {
    Invoke-WebRequest $source.url -OutFile "sources/$($source.name)"
    if ((Get-FileHash "sources/$($source.name)").Hash.ToLowerInvariant() -ne $source.sha256) { throw 'Pinned source hash mismatch' }
}
. ./builder/php/BuildPhp/private/Invoke-CompatRunTestsPatch.ps1
$patch = (Resolve-Path builder/php/BuildPhp/config/run-tests/run-tests-8.2-plus.patch).Path
if (!(Invoke-CompatRunTestsPatch -Path (Resolve-Path sources/run-tests.php).Path -PatchPath $patch)) { throw 'Could not reproduce source CI worker setup' }
Get-FileHash sources/run-tests.php, $patch | ConvertTo-Json | Set-Content reports/runner-hashes.json
$testName = if ($Kind -eq 'write') { 'bug72333.phpt' } else { 'tls_psk_tls13_basic.phpt' }
$original = [IO.File]::ReadAllText((Resolve-Path "sources/$testName"))
if ($Kind -eq 'write') {
$control = $original.Replace('        $total = 0;', '        $total = 0; $originalLength = strlen($buf);').Replace('if ($total >= strlen($buf))', 'if ($total >= $originalLength)').Replace('$buf = substr($buf, $total);', '$buf = substr($buf, $result);')
if ($control -eq $original -or $control.Contains('$buf = substr($buf, $total);')) { throw 'Expected buffer-offset code absent' }
[IO.File]::WriteAllText((Join-Path $workspace 'reports/buffer-offset-control.phpt'), $control)
$modes = @('original','buffer-offset-control')
} else { $modes = @('original') }
foreach ($mode in $modes) {
    for ($i=1; $i -le 500; $i++) {
        $dir = Join-Path $workspace "cases/$mode-$i"
        New-Item $dir -ItemType Directory | Out-Null
        Get-ChildItem sources -File | Where-Object Extension -In '.inc','.cnf' | Copy-Item -Destination $dir
        [IO.File]::WriteAllText((Join-Path $dir $testName), $(if ($mode -eq 'original') {$original} else {$control}))
    }
}
foreach ($credential in @(Get-ChildItem Env: | Where-Object Name -Match '(?i)TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY')) { Remove-Item "Env:$($credential.Name)" }
$info = (& $exe --ri openssl) -join "`n"
$info | Set-Content reports/openssl-version.txt
if ($LASTEXITCODE -ne 0 -or $info -notmatch "(?m)^OpenSSL Library Version\s*=>\s*(OpenSSL $([regex]::Escape($OpenSsl))[^\r\n]*)") { throw 'Wrong OpenSSL runtime loaded' }
$version = $Matches[1]
& $exe -r 'echo json_encode(["ini"=>php_ini_loaded_file(),"extensions"=>get_loaded_extensions(),"opcache"=>ini_get("opcache.enable_cli")]);' | Set-Content reports/runtime-configuration.json
if ($Kind -eq 'write') {
    # CertificateGenerator.inc reads its sibling openssl.cnf. Validate the full
    # fixture before treating any repeated test failure as SSL-write evidence.
    & $exe -r 'set_error_handler(static function($n,$s) { throw new Exception($s); }); require "sources/CertificateGenerator.inc"; $g = new CertificateGenerator(); $g->saveNewCertAsFileWithKey("bug72333", "reports/preflight.pem"); if (!openssl_x509_parse(file_get_contents("reports/preflight.pem"))) { exit(1); } echo "certificate fixture valid";' | Tee-Object reports/certificate-preflight.txt | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Certificate fixture setup failed' }
    Remove-Item reports/preflight.pem
}
$env:TEST_PHP_JUNIT = Join-Path $workspace 'reports/results.xml'
& $exe -n -d open_basedir= -d output_buffering=0 sources/run-tests.php -p $exe -n -c (Join-Path $env:PHPRC 'php.ini') -d "extension_dir=$workspace\runtime\ext" -j6 -q --offline --show-diff --set-timeout 90 cases 2>&1 | Tee-Object reports/tests.log | Out-Host
$exitCode = $LASTEXITCODE
[xml]$xml = Get-Content reports/results.xml -Raw
$result = @{kind=$Kind; runId=$row.runId; sourceCommit=$row.sourceCommit; runtime=$runtime.name; runtimeSha256=$runtime.sha256; openssl=$version; package=$package; files=$files; cases=@($xml.SelectNodes('//testcase')).Count; failures=@($xml.SelectNodes('//failure|//error')).Count; skipped=@($xml.SelectNodes('//skipped')).Count; exit=$exitCode}
$result | ConvertTo-Json -Depth 10 | Set-Content reports/summary.json
Copy-Item "sources/$testName" reports
Stop-Transcript
if ($result.cases -ne (500 * $modes.Count) -or $result.skipped -ne 0 -or $result.failures -ne 0 -or $exitCode -ne 0) { throw 'Inspect retained SSL diagnostic evidence' }
