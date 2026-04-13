param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('legacy', 'updated')]
  [string]$ConfigMode,

  [Parameter(Mandatory = $true)]
  [string]$PhpVersionUnderTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Convert-ToIniPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return ($Path -replace '\\', '/')
}

function Get-EnvValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if (Test-Path "Env:$Name") {
    return (Get-Item "Env:$Name").Value
  }

  return $null
}

function Restore-EnvValue {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [AllowNull()]
    [string]$Value
  )

  if ($null -eq $Value) {
    Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
    return
  }

  Set-Item "Env:$Name" -Value $Value
}

function Write-TextFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string[]]$Lines
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  Set-Content -Path $Path -Value ($Lines -join [Environment]::NewLine)
}

function Assert-ExtensionDll {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $path = Join-Path $script:ExtDir ("php_{0}.dll" -f $Name)
  if (-not (Test-Path $path)) {
    throw "Missing expected extension DLL: $path"
  }

  return $path
}

function Invoke-PhpCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Binary,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$ScanDir,

    [hashtable]$Environment = @{}
  )

  $saved = @{}
  $names = @('PHP_INI_SCAN_DIR') + $Environment.Keys
  foreach ($envName in ($names | Select-Object -Unique)) {
    $saved[$envName] = Get-EnvValue -Name $envName
  }

  try {
    Set-Item Env:PHP_INI_SCAN_DIR -Value $ScanDir
    foreach ($pair in $Environment.GetEnumerator()) {
      Set-Item "Env:$($pair.Key)" -Value ([string]$pair.Value)
    }

    $output = & $Binary @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    foreach ($envName in $saved.Keys) {
      Restore-EnvValue -Name $envName -Value $saved[$envName]
    }
  }

  $text = if ($null -eq $output) { '' } else { ($output | Out-String).TrimEnd() }
  $logPath = Join-Path $script:ScenarioRoot ("{0}.log" -f $Name)
  Set-Content -Path $logPath -Value $text

  Write-Host ("[{0}] {1} {2}" -f $Name, $Binary, ($Arguments -join ' '))
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    Write-Host $text
  }

  if ($exitCode -ne 0) {
    throw "Command '$Name' failed with exit code $exitCode"
  }

  return $text
}

function New-ReproductionConfig {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('legacy', 'updated')]
    [string]$Mode
  )

  $configRoot = Join-Path $script:ScenarioRoot $Mode
  $scanDir = Join-Path $configRoot 'scan'
  $mainIni = Join-Path $configRoot 'php.ini'
  $errorLog = Convert-ToIniPath (Join-Path $script:ScenarioRoot ("{0}-php-error.log" -f $Mode))
  $caFileCandidates = @(
    (Join-Path $script:PhpDir 'ssl\cacert.pem'),
    (Join-Path $script:PhpDir 'extras\ssl\cacert.pem')
  )
  $caFile = $caFileCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  $caDirectives = @()

  if ($null -ne $caFile) {
    $iniCaFile = Convert-ToIniPath $caFile
    $caDirectives += ('curl.cainfo="{0}"' -f $iniCaFile)
    $caDirectives += ('openssl.cafile="{0}"' -f $iniCaFile)
  }

  New-Item -ItemType Directory -Path $configRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $scanDir -Force | Out-Null

  if ($Mode -eq 'legacy') {
    Write-TextFile -Path $mainIni -Lines @(
      'date.timezone=UTC',
      'display_errors=stdout',
      'display_startup_errors=1',
      'enable_dl=1',
      ('error_log="{0}"' -f $errorLog),
      ('extension_dir="{0}"' -f (Convert-ToIniPath $script:ExtDir)),
      'implicit_flush=1',
      'include_path=".;C:\php\pear"',
      'log_errors=0',
      'max_execution_time=0',
      'memory_limit=128M',
      'output_buffering=0',
      'post_max_size=8M',
      'short_open_tag=1',
      'upload_max_filesize=2M',
      'user_ini.filename=.user.ini',
      'cgi.force_redirect=0'
    )

    Write-TextFile -Path (Join-Path $scanDir 'redis.ini') -Lines @(
      'session.save_handler=redis',
      'session.save_path="tcp://127.0.0.1:6379?weight=1&prefix=XXX_SESSION_&database=0"'
    )

    return [pscustomobject]@{
      MainIni = $mainIni
      ScanDir = $scanDir
      ExpectedLoaded = @()
      ExpectedMissing = @('curl', 'intl', 'mbstring', 'openssl', 'redis', 'igbinary', 'pgsql', 'pdo_pgsql', 'soap')
      SessionSerializer = 'php'
    }
  }

  $requiredExtensions = @(
    'openssl',
    'curl',
    'intl',
    'mbstring',
    'exif',
    'fileinfo',
    'gd',
    'gettext',
    'pgsql',
    'pdo_pgsql',
    'soap',
    'igbinary',
    'redis'
  )

  foreach ($extension in $requiredExtensions) {
    Assert-ExtensionDll -Name $extension | Out-Null
  }

  Write-TextFile -Path $mainIni -Lines @(
    'cgi.force_redirect=0'
  )

  Write-TextFile -Path (Join-Path $scanDir '01_commons.ini') -Lines @(
    'date.timezone=Europe/Berlin',
    'display_errors=stdout',
    'display_startup_errors=1',
    'enable_dl=0',
    'error_reporting=30719',
    'expose_php=0',
    ('extension_dir="{0}"' -f (Convert-ToIniPath $script:ExtDir)),
    'include_path="."',
    'log_errors=1',
    'max_execution_time=0',
    'memory_limit=128M',
    'output_buffering=0',
    'post_max_size=0',
    'realpath_cache_size=5096k',
    'realpath_cache_ttl=3600',
    'request_order=GP',
    'short_open_tag=0',
    'upload_max_filesize=150M',
    'user_ini.filename=',
    'variables_order=GPCS',
    'extension=php_openssl.dll',
    'extension=php_curl.dll',
    'extension=php_intl.dll',
    'extension=php_mbstring.dll',
    'extension=php_exif.dll',
    'extension=php_fileinfo.dll',
    'extension=php_gd.dll',
    'extension=php_gettext.dll'
  )

  Write-TextFile -Path (Join-Path $scanDir '02_error_handling.ini') -Lines @(
    ('error_log="{0}"' -f $errorLog),
    'error_log_mode=0644',
    'zend.exception_ignore_args=1',
    'zend.exception_string_param_max_len=0'
  )

  Write-TextFile -Path (Join-Path $scanDir '02_webserver_nginx.ini') -Lines @(
    'display_startup_errors=1'
  )

  Write-TextFile -Path (Join-Path $scanDir '03_psql.ini') -Lines @(
    'extension=php_pgsql.dll',
    'extension=php_pdo_pgsql.dll'
  )

  Write-TextFile -Path (Join-Path $scanDir '04_soap.ini') -Lines @(
    'extension=php_soap.dll'
  )

  Write-TextFile -Path (Join-Path $scanDir '05_session.ini') -Lines @(
    'session.cookie_httponly=1',
    'session.cookie_samesite=Strict',
    'session.gc_maxlifetime=86400',
    'session.gc_probability=0',
    'session.name=XXX_SESSION',
    'session.save_handler=redis',
    'session.save_path="tcp://127.0.0.1:6379?weight=1&prefix=XXX_SESSION_&database=0"',
    'session.serialize_handler=igbinary',
    'session.use_strict_mode=1'
  )

  Write-TextFile -Path (Join-Path $scanDir '06_igbinary.ini') -Lines @(
    'extension=php_igbinary.dll'
  )

  Write-TextFile -Path (Join-Path $scanDir '10_redis.ini') -Lines @(
    'extension=php_redis.dll',
    'redis.session.compression=lz4',
    'redis.session.compression_level=5',
    'redis.session.lock_expire=60',
    'redis.session.lock_retries=200',
    'redis.session.lock_wait_time=50000',
    'redis.session.locking_enabled=0'
  )

  if ($caDirectives.Count -gt 0) {
    Add-Content -Path (Join-Path $scanDir '01_commons.ini') -Value ($caDirectives -join [Environment]::NewLine)
  }

  Add-Content -Path (Join-Path $scanDir '01_commons.ini') -Value [Environment]::NewLine
  Add-Content -Path (Join-Path $scanDir '01_commons.ini') -Value 'intl.default_locale=de-DE'

  return [pscustomobject]@{
    MainIni = $mainIni
    ScanDir = $scanDir
    ExpectedLoaded = @('curl', 'intl', 'mbstring', 'openssl', 'redis', 'igbinary', 'pgsql', 'pdo_pgsql', 'soap')
    ExpectedMissing = @()
    SessionSerializer = 'igbinary'
  }
}

$script:ArtifactRoot = Join-Path $env:RUNNER_TEMP 'issue-21697-comment'
$script:ScenarioRoot = Join-Path $script:ArtifactRoot ("{0}-{1}" -f $PhpVersionUnderTest, $ConfigMode)
New-Item -ItemType Directory -Path $script:ScenarioRoot -Force | Out-Null

$script:PhpExe = (Get-Command php).Source
$script:PhpCgi = (Get-Command php-cgi).Source
$script:PhpDir = Split-Path -Parent $script:PhpExe
$script:ExtDir = Join-Path $script:PhpDir 'ext'

if (-not (Test-Path $script:PhpExe)) {
  throw "Could not find php.exe"
}

if (-not (Test-Path $script:PhpCgi)) {
  throw "Could not find php-cgi.exe"
}

$actualVersion = Invoke-PhpCommand -Name 'php-version-check' -Binary $script:PhpExe -Arguments @('-n', '-r', 'echo PHP_VERSION;') -ScanDir ''
if ($actualVersion -ne $PhpVersionUnderTest) {
  throw "Expected PHP version $PhpVersionUnderTest, got $actualVersion"
}

$config = New-ReproductionConfig -Mode $ConfigMode

$smokeScript = Join-Path $script:ScenarioRoot 'extension-smoke.php'
Write-TextFile -Path $smokeScript -Lines @(
  '<?php',
  'error_reporting(E_ALL);',
  'ini_set("display_errors", "1");',
  '',
  '$expectedLoaded = array_values(array_filter(array_map("trim", explode(",", getenv("EXPECTED_LOADED") ?: ""))));',
  '$expectedMissing = array_values(array_filter(array_map("trim", explode(",", getenv("EXPECTED_MISSING") ?: ""))));',
  '$expectedSessionSerializer = getenv("EXPECTED_SESSION_SERIALIZER") ?: "";',
  '$trackedExtensions = ["curl", "intl", "mbstring", "openssl", "redis", "igbinary", "pgsql", "pdo_pgsql", "soap"];',
  '',
  '$assert = static function (bool $condition, string $message) : void {',
  '    if (!$condition) {',
  '        throw new RuntimeException($message);',
  '    }',
  '};',
  '',
  'foreach ($expectedLoaded as $extension) {',
  '    $assert(extension_loaded($extension), "Expected extension to be loaded: {$extension}");',
  '}',
  '',
  'foreach ($expectedMissing as $extension) {',
  '    $assert(!extension_loaded($extension), "Expected extension to be disabled: {$extension}");',
  '}',
  '',
  'if (extension_loaded("curl")) {',
  '    $version = curl_version();',
  '    $assert(is_array($version) && !empty($version["version"]), "curl_version() did not return version data");',
  '}',
  '',
  'if (extension_loaded("intl")) {',
  '    $assert(class_exists(Normalizer::class), "Normalizer class is missing");',
  '    $assert(Normalizer::normalize("Cafe\u{0301}") === "Caf\u{00E9}", "Normalizer failed to normalize text");',
  '}',
  '',
  'if (extension_loaded("mbstring")) {',
  '    $assert(mb_strlen("Gr\u{00FC}\u{00DF}e", "UTF-8") === 5, "mb_strlen returned an unexpected value");',
  '}',
  '',
  'if (extension_loaded("redis")) {',
  '    $assert(class_exists(Redis::class), "Redis class is missing");',
  '}',
  '',
  'if (extension_loaded("igbinary")) {',
  '    $assert(function_exists("igbinary_serialize"), "igbinary_serialize() is missing");',
  '    $payload = igbinary_unserialize(igbinary_serialize(["ok" => true]));',
  '    $assert(isset($payload["ok"]) && $payload["ok"] === true, "igbinary round-trip failed");',
  '}',
  '',
  'if (extension_loaded("pgsql")) {',
  '    $assert(function_exists("pg_connect"), "pg_connect() is missing");',
  '}',
  '',
  'if (extension_loaded("pdo_pgsql")) {',
  '    $assert(in_array("pgsql", PDO::getAvailableDrivers(), true), "PDO pgsql driver is missing");',
  '}',
  '',
  'if (extension_loaded("soap")) {',
  '    $assert(class_exists(SoapClient::class), "SoapClient class is missing");',
  '}',
  '',
  '$sessionSavePath = (string) ini_get("session.save_path");',
  '$assert(ini_get("session.save_handler") === "redis", "session.save_handler is not redis");',
  'if ($expectedSessionSerializer !== "") {',
  '    $assert(ini_get("session.serialize_handler") === $expectedSessionSerializer, "session.serialize_handler does not match the expected value");',
  '}',
  '$assert(str_contains($sessionSavePath, "127.0.0.1:6379"), "session.save_path does not contain the expected Redis endpoint");',
  '',
  '$result = [',
  '    "php_version" => PHP_VERSION,',
  '    "sapi" => PHP_SAPI,',
  '    "loaded_tracked_extensions" => array_values(array_filter($trackedExtensions, "extension_loaded")),',
  '    "session_save_handler" => ini_get("session.save_handler"),',
  '    "session_save_path" => $sessionSavePath,',
  '    "session_serialize_handler" => ini_get("session.serialize_handler"),',
  '];',
  '',
  'echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;'
)

$envOverrides = @{
  EXPECTED_LOADED = ($config.ExpectedLoaded -join ',')
  EXPECTED_MISSING = ($config.ExpectedMissing -join ',')
  EXPECTED_SESSION_SERIALIZER = $config.SessionSerializer
}

Invoke-PhpCommand -Name 'php-n-modules' -Binary $script:PhpExe -Arguments @('-n', '-m') -ScanDir ''
Invoke-PhpCommand -Name 'php-cgi-n-modules' -Binary $script:PhpCgi -Arguments @('-n', '-m') -ScanDir ''
Invoke-PhpCommand -Name 'php-cli-modules' -Binary $script:PhpExe -Arguments @('-c', $config.MainIni, '-m') -ScanDir $config.ScanDir
Invoke-PhpCommand -Name 'php-cgi-modules' -Binary $script:PhpCgi -Arguments @('-c', $config.MainIni, '-m') -ScanDir $config.ScanDir
Invoke-PhpCommand -Name 'php-cli-info' -Binary $script:PhpExe -Arguments @('-c', $config.MainIni, '-i') -ScanDir $config.ScanDir
$cliSmoke = Invoke-PhpCommand -Name 'php-cli-extension-smoke' -Binary $script:PhpExe -Arguments @('-c', $config.MainIni, $smokeScript) -ScanDir $config.ScanDir -Environment $envOverrides
$cgiSmoke = Invoke-PhpCommand -Name 'php-cgi-extension-smoke' -Binary $script:PhpCgi -Arguments @('-q', '-c', $config.MainIni, '-f', $smokeScript) -ScanDir $config.ScanDir -Environment $envOverrides

$summaryLines = @(
  "### PHP $PhpVersionUnderTest / $ConfigMode",
  '',
  '- `php.exe` and `php-cgi.exe` both started successfully with the reconstructed config.',
  ('- Expected loaded extensions: `{0}`' -f $(if ($config.ExpectedLoaded.Count -eq 0) { 'none' } else { $config.ExpectedLoaded -join ', ' })),
  ('- Expected missing extensions: `{0}`' -f $(if ($config.ExpectedMissing.Count -eq 0) { 'none' } else { $config.ExpectedMissing -join ', ' })),
  ('- CLI smoke output saved to `{0}`.' -f (Join-Path $script:ScenarioRoot 'php-cli-extension-smoke.log')),
  ('- CGI smoke output saved to `{0}`.' -f (Join-Path $script:ScenarioRoot 'php-cgi-extension-smoke.log'))
)

Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($summaryLines -join [Environment]::NewLine)

Write-Host 'CLI smoke result:'
Write-Host $cliSmoke
Write-Host 'CGI smoke result:'
Write-Host $cgiSmoke
