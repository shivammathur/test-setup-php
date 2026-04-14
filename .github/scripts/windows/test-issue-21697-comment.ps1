param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('legacy', 'updated')]
  [string]$ConfigMode,

  [ValidateSet('disabled', 'tracing-default', 'tracing-cli-hot', '1254-hot', '1205-hot')]
  [string]$OpcacheProfile = 'disabled',

  [ValidateSet('full', 'builtin-only')]
  [string]$WebMode = 'full',

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
    [AllowEmptyString()]
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

function Wait-ForTcpPort {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [Parameter(Mandatory = $true)]
    [int]$Port,

    [int]$Attempts = 30
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $client = $null

    try {
      $client = [System.Net.Sockets.TcpClient]::new()
      $client.Connect($HostName, $Port)
      if ($client.Connected) {
        $client.Close()
        return
      }
    } catch {
    } finally {
      if ($null -ne $client) {
        $client.Dispose()
      }
    }

    Start-Sleep -Seconds 1
  }

  throw "Timed out waiting for ${HostName}:$Port"
}

function Wait-ForHttpUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [int]$Attempts = 30
  )

  $bodyPath = Join-Path $script:ScenarioRoot ('http-probe-{0}.txt' -f ([System.Guid]::NewGuid().ToString('N')))
  $lastStatusCode = ''
  $lastOutput = ''

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    if (Test-Path $bodyPath) {
      Remove-Item -Path $bodyPath -Force
    }

    $statusCode = & curl.exe --silent --show-error --location --output $bodyPath --write-out '%{http_code}' --max-time 10 $Url 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0 -and $statusCode -eq '200') {
      if (Test-Path $bodyPath) {
        Remove-Item -Path $bodyPath -Force
      }
      return
    }

    $lastStatusCode = ($statusCode | Out-String).Trim()
    if (Test-Path $bodyPath) {
      $lastOutput = Get-Content -Path $bodyPath -Raw
    }
    Start-Sleep -Seconds 1
  }

  if (-not [string]::IsNullOrWhiteSpace($lastOutput)) {
    Write-Host $lastOutput
  }

  throw "Timed out waiting for $Url (last status: $lastStatusCode)"
}

function Assert-StringArrayEqual {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$Actual,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$Expected,

    [Parameter(Mandatory = $true)]
    [string]$Label
  )

  $actualText = (($Actual | Sort-Object) -join ',')
  $expectedText = (($Expected | Sort-Object) -join ',')

  if ($actualText -ne $expectedText) {
    throw "$Label mismatch. Expected '$expectedText', got '$actualText'"
  }
}

function Assert-WebResult {
  param(
    [Parameter(Mandatory = $true)]
    [psobject]$Result,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$ExpectedLoaded,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSerializer,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSapi,

    [string]$ExpectedServerPattern = '',

    [AllowNull()]
    [object]$ExpectedOpcacheLoaded = $null,

    [AllowNull()]
    [object]$ExpectedOpcacheEnabled = $null,

    [AllowNull()]
    [string]$ExpectedJit = $null
  )

  if ($Result.php_version -ne $PhpVersionUnderTest) {
    throw "Expected web PHP version $PhpVersionUnderTest, got $($Result.php_version)"
  }

  if ($Result.sapi -ne $ExpectedSapi) {
    throw "Expected web SAPI $ExpectedSapi, got $($Result.sapi)"
  }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedServerPattern) -and ($Result.server_software | Out-String).Trim() -notmatch $ExpectedServerPattern) {
    throw "Expected server software matching '$ExpectedServerPattern', got '$($Result.server_software)'"
  }

  if ($null -ne $ExpectedOpcacheLoaded -and [bool]$Result.opcache_loaded -ne [bool]$ExpectedOpcacheLoaded) {
    throw "Expected opcache_loaded=$ExpectedOpcacheLoaded, got $($Result.opcache_loaded)"
  }

  if ($null -ne $ExpectedOpcacheEnabled -and [bool]$Result.opcache_enabled -ne [bool]$ExpectedOpcacheEnabled) {
    throw "Expected opcache_enabled=$ExpectedOpcacheEnabled, got $($Result.opcache_enabled)"
  }

  if ($null -ne $ExpectedJit -and $Result.opcache_jit -ne $ExpectedJit) {
    throw "Expected opcache.jit=$ExpectedJit, got $($Result.opcache_jit)"
  }

  Assert-StringArrayEqual -Actual @($Result.loaded_tracked_extensions) -Expected $ExpectedLoaded -Label 'Loaded web extensions'

  if ($Result.session_save_handler -ne 'redis') {
    throw "Expected session.save_handler=redis, got $($Result.session_save_handler)"
  }

  if ($Result.session_serialize_handler -ne $ExpectedSerializer) {
    throw "Expected session.serialize_handler=$ExpectedSerializer, got $($Result.session_serialize_handler)"
  }

  if (($Result.session_save_path | Out-String).Trim() -notmatch '127\.0\.0\.1:6379') {
    throw "Unexpected session.save_path: $($Result.session_save_path)"
  }
}

function Invoke-CurlJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Url
  )

  $output = & curl.exe --silent --show-error --fail --location --max-time 20 $Url 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).TrimEnd()
  $logPath = Join-Path $script:ScenarioRoot ("{0}.log" -f $Name)
  Set-Content -Path $logPath -Value $text

  Write-Host ("[{0}] curl.exe {1}" -f $Name, $Url)
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    Write-Host $text
  }

  if ($exitCode -ne 0) {
    throw "curl for '$Name' failed with exit code $exitCode"
  }

  return ($text | ConvertFrom-Json)
}

function Invoke-RepeatedCurlJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$NamePrefix,

    [Parameter(Mandatory = $true)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [int]$Count
  )

  $results = @()
  for ($index = 1; $index -le $Count; $index++) {
    $separator = if ($Url.Contains('?')) { '&' } else { '?' }
    $requestUrl = '{0}{1}request={2}' -f $Url, $separator, $index
    $results += ,(Invoke-CurlJson -Name ('{0}-{1:D2}' -f $NamePrefix, $index) -Url $requestUrl)
  }

  return $results
}

function Assert-RepeatedWebResults {
  param(
    [Parameter(Mandatory = $true)]
    [psobject[]]$Results,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$ExpectedLoaded,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSerializer,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSapi,

    [string]$ExpectedServerPattern = '',

    [AllowNull()]
    [object]$ExpectedOpcacheLoaded = $null,

    [AllowNull()]
    [object]$ExpectedOpcacheEnabled = $null,

    [AllowNull()]
    [string]$ExpectedJit = $null,

    [AllowNull()]
    [object]$ExpectStablePid = $null,

    [AllowNull()]
    [string]$Label = $null
  )

  foreach ($result in $Results) {
    Assert-WebResult `
      -Result $result `
      -ExpectedLoaded $ExpectedLoaded `
      -ExpectedSerializer $ExpectedSerializer `
      -ExpectedSapi $ExpectedSapi `
      -ExpectedServerPattern $ExpectedServerPattern `
      -ExpectedOpcacheLoaded $ExpectedOpcacheLoaded `
      -ExpectedOpcacheEnabled $ExpectedOpcacheEnabled `
      -ExpectedJit $ExpectedJit
  }

  if ($ExpectStablePid) {
    $pids = @($Results | ForEach-Object { [string]$_.pid } | Sort-Object -Unique)
    if ($pids.Count -ne 1) {
      $name = if ([string]::IsNullOrWhiteSpace($Label)) { 'request set' } else { $Label }
      throw "Expected a stable PID for $name, got $($pids -join ', ')"
    }
  }
}

function Ensure-IisReady {
  if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
    $features = @('Web-Server', 'Web-Static-Content', 'Web-Default-Doc', 'Web-Http-Errors', 'Web-Http-Logging', 'Web-CGI')
    $result = Install-WindowsFeature -Name $features -IncludeManagementTools
    if (-not $result.Success) {
      throw 'Failed to install or verify IIS features'
    }
  } else {
    $features = @('IIS-WebServerRole', 'IIS-WebServer', 'IIS-StaticContent', 'IIS-DefaultDocument', 'IIS-HttpErrors', 'IIS-HttpLogging', 'IIS-CGI')
    foreach ($feature in $features) {
      Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
    }
  }

  Start-Service WAS -ErrorAction SilentlyContinue
  Start-Service W3SVC -ErrorAction SilentlyContinue

  $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
  if (-not (Test-Path $appcmd)) {
    throw 'IIS appcmd.exe was not found after enabling IIS features'
  }

  return $appcmd
}

function Invoke-AppCmdChecked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$AppCmd,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $output = & $AppCmd @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).TrimEnd()

  Write-Host ("[appcmd] {0}" -f ($Arguments -join ' '))
  if (-not [string]::IsNullOrWhiteSpace($text)) {
    Write-Host $text
  }

  if ($exitCode -ne 0) {
    throw "Failed to $Description"
  }
}

function Invoke-IisWebSmoke {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Config,

    [Parameter(Mandatory = $true)]
    [string]$WebRoot
  )

  $appcmd = Ensure-IisReady

  $siteName = 'Issue21697CommentSite'
  $appPool = 'Issue21697CommentPool'
  $port = 8050
  $fastCgiArgs = '-c "' + $Config.MainIni + '"'
  $webConfigPath = Join-Path $WebRoot 'web.config'
  $scriptProcessor = '{0}|-c "{1}"' -f $script:PhpCgi, $Config.MainIni

  & $appcmd delete site "/site.name:$siteName" 2>$null | Out-Null
  & $appcmd delete apppool "/apppool.name:$appPool" 2>$null | Out-Null

  Write-TextFile -Path $webConfigPath -Lines @(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<configuration>',
    '  <system.webServer>',
    '    <handlers>',
    ('      <add name="PHP-Issue21697-Handler" path="*.php" verb="GET,HEAD,POST" modules="FastCgiModule" scriptProcessor="{0}" resourceType="Either" requireAccess="Script" />' -f ($scriptProcessor -replace '"', '&quot;')),
    '    </handlers>',
    '  </system.webServer>',
    '</configuration>'
  )

  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('add', 'apppool', "/name:$appPool") -Description 'create the IIS application pool'
  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('set', 'apppool', "/apppool.name:$appPool", '/managedRuntimeVersion:', '/managedPipelineMode:Integrated') -Description 'configure the IIS application pool'
  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('add', 'site', "/name:$siteName", ("/bindings:http/*:{0}:" -f $port), "/physicalPath:$WebRoot") -Description 'create the IIS site'
  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('set', 'app', "$siteName/", "/applicationPool:$appPool") -Description 'assign the IIS application pool to the site root'

  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('set', 'config', '/section:system.webServer/fastCgi', ("/+[fullPath='{0}',arguments='{1}']" -f $script:PhpCgi, $fastCgiArgs), '/commit:apphost') -Description 'configure the IIS FastCGI application'
  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('set', 'config', '/section:system.webServer/fastCgi', ("/[fullPath='{0}',arguments='{1}'].maxInstances:1" -f $script:PhpCgi, $fastCgiArgs), '/commit:apphost') -Description 'limit IIS FastCGI to one backend process'
  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('set', 'config', '/section:system.webServer/fastCgi', ("/[fullPath='{0}',arguments='{1}'].instanceMaxRequests:1000" -f $script:PhpCgi, $fastCgiArgs), '/commit:apphost') -Description 'configure IIS FastCGI request recycling'
  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('set', 'config', '/section:system.webServer/fastCgi', ("/+[fullPath='{0}',arguments='{1}'].environmentVariables.[name='PHP_INI_SCAN_DIR',value='{2}']" -f $script:PhpCgi, $fastCgiArgs, $Config.ScanDir), '/commit:apphost') -Description 'configure IIS FastCGI environment variables'
  Invoke-AppCmdChecked -AppCmd $appcmd -Arguments @('start', 'site', "/site.name:$siteName") -Description 'start the IIS site'

  $url = 'http://127.0.0.1:{0}/web-stress.php' -f $port
  Wait-ForHttpUrl -Url $url

  $results = Invoke-RepeatedCurlJson -NamePrefix 'iis-web-stress' -Url $url -Count $script:RepeatedRequestCount
  Assert-RepeatedWebResults `
    -Results $results `
    -ExpectedLoaded $Config.ExpectedLoaded `
    -ExpectedSerializer $Config.SessionSerializer `
    -ExpectedSapi 'cgi-fcgi' `
    -ExpectedServerPattern 'IIS' `
    -ExpectedOpcacheLoaded $Config.ExpectOpcacheLoaded `
    -ExpectedOpcacheEnabled $Config.ExpectWebOpcacheEnabled `
    -ExpectedJit $Config.ExpectedJitValue `
    -ExpectStablePid $true `
    -Label 'IIS FastCGI'
}

function Get-ApacheHttpdPath {
  $command = Get-Command httpd.exe -ErrorAction SilentlyContinue
  if ($null -ne $command -and (Test-Path $command.Source)) {
    return $command.Source
  }

  $candidates = @(
    'C:\tools\Apache24\bin\httpd.exe',
    'C:\Apache24\bin\httpd.exe',
    'C:\Program Files\Apache Group\Apache2\bin\httpd.exe'
  )

  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  $roots = @('C:\tools', 'C:\Apache24', 'C:\Program Files')
  foreach ($root in $roots) {
    if (Test-Path $root) {
      $found = Get-ChildItem -Path $root -Filter httpd.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
      if (-not [string]::IsNullOrWhiteSpace($found)) {
        return $found
      }
    }
  }

  return $null
}

function Install-ApacheFromApacheLounge {
  $downloadPage = Invoke-WebRequest -Uri 'https://www.apachelounge.com/download/'
  $matches = [regex]::Matches($downloadPage.Content, 'httpd-[^"'' ]*Win64-VS17\.zip')
  if ($matches.Count -eq 0) {
    throw 'Could not find an Apache Lounge Win64 VS17 archive on the download page'
  }

  $archiveName = $matches[0].Value
  $archiveUrl = 'https://www.apachelounge.com/download/VS17/binaries/{0}' -f $archiveName
  $archivePath = Join-Path $env:RUNNER_TEMP $archiveName
  $extractRoot = Join-Path $env:RUNNER_TEMP 'apache-httpd'

  if (Test-Path $extractRoot) {
    Remove-Item -Path $extractRoot -Recurse -Force
  }

  Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath
  Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force

  $httpd = Get-ChildItem -Path $extractRoot -Filter httpd.exe -Recurse | Select-Object -First 1 -ExpandProperty FullName
  if ([string]::IsNullOrWhiteSpace($httpd)) {
    throw 'Apache Lounge archive did not contain httpd.exe'
  }

  return $httpd
}

function Ensure-ApacheInstalled {
  $httpd = Get-ApacheHttpdPath
  if (-not [string]::IsNullOrWhiteSpace($httpd)) {
    return $httpd
  }

  if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
    & choco.exe install apache-httpd -y --no-progress
    if ($LASTEXITCODE -eq 0) {
      $httpd = Get-ApacheHttpdPath
      if (-not [string]::IsNullOrWhiteSpace($httpd)) {
        return $httpd
      }
    }
  }

  return Install-ApacheFromApacheLounge
}

function Invoke-ApacheCgiWebSmoke {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Config,

    [Parameter(Mandatory = $true)]
    [string]$WebRoot
  )

  $httpd = Ensure-ApacheInstalled
  $apacheRoot = Split-Path -Parent (Split-Path -Parent $httpd)
  $defaultConf = Join-Path $apacheRoot 'conf\httpd.conf'
  $defaultConfLines = Get-Content -Path $defaultConf
  $moduleLines = @($defaultConfLines | Where-Object { $_ -match '^\s*LoadModule ' })
  $requiredModulePatterns = @('actions_module', 'alias_module', 'cgi_module', 'env_module')

  foreach ($modulePattern in $requiredModulePatterns) {
    if (-not ($moduleLines | Where-Object { $_ -match ("LoadModule\s+{0}\s+" -f $modulePattern) })) {
      $line = $defaultConfLines | Where-Object { $_ -match ("^\s*#\s*LoadModule\s+{0}\s+" -f $modulePattern) } | Select-Object -First 1
      if ($null -eq $line) {
        throw "Could not find Apache module line for $modulePattern"
      }

      $moduleLines += ($line -replace '^\s*#\s*', '')
    }
  }

  $port = 8051
  $apacheConf = Join-Path $script:ScenarioRoot 'apache-httpd.conf'
  $apachePid = Join-Path $script:ScenarioRoot 'apache-httpd.pid'
  $apacheErrorLog = Join-Path $script:ScenarioRoot 'apache-error.log'
  $apacheAccessLog = Join-Path $script:ScenarioRoot 'apache-access.log'
  $apacheStdout = Join-Path $script:ScenarioRoot 'apache-stdout.log'
  $apacheStderr = Join-Path $script:ScenarioRoot 'apache-stderr.log'
  $apacheProcess = $null
  $phpConfigDir = Convert-ToIniPath (Split-Path -Parent $Config.MainIni)
  $phpDirPath = Convert-ToIniPath $script:PhpDir
  $phpScanDir = Convert-ToIniPath $Config.ScanDir

  Write-TextFile -Path $apacheConf -Lines (@(
    ('ServerRoot "{0}"' -f (Convert-ToIniPath $apacheRoot)),
    ('DefaultRuntimeDir "{0}"' -f (Convert-ToIniPath $script:ScenarioRoot)),
    ('Listen 127.0.0.1:{0}' -f $port),
    ('ServerName 127.0.0.1:{0}' -f $port),
    ('PidFile "{0}"' -f (Convert-ToIniPath $apachePid)),
    ('ErrorLog "{0}"' -f (Convert-ToIniPath $apacheErrorLog)),
    'LogLevel warn'
  ) + $moduleLines + @(
    ('TypesConfig "{0}"' -f (Convert-ToIniPath (Join-Path $apacheRoot 'conf\mime.types'))),
    ('DocumentRoot "{0}"' -f (Convert-ToIniPath $WebRoot)),
    '<Directory />',
    '  AllowOverride none',
    '  Require all denied',
    '</Directory>',
    ('<Directory "{0}">' -f (Convert-ToIniPath $WebRoot)),
    '  Options Indexes FollowSymLinks',
    '  AllowOverride None',
    '  Require all granted',
    '</Directory>',
    ('<Directory "{0}">' -f $phpDirPath),
    '  AllowOverride None',
    '  Options ExecCGI',
    '  Require all granted',
    '</Directory>',
    'LogFormat "%h %l %u %t \"%r\" %>s %b" common',
    ('CustomLog "{0}" common' -f (Convert-ToIniPath $apacheAccessLog)),
    'DirectoryIndex web-stress.php web-smoke.php',
    ('ScriptAlias /php-cgi/ "{0}/"' -f $phpDirPath),
    'Action php-script "/php-cgi/php-cgi.exe"',
    'AddHandler php-script .php',
    ('SetEnv PHPRC "{0}"' -f $phpConfigDir),
    ('SetEnv PHP_INI_SCAN_DIR "{0}"' -f $phpScanDir),
    'SetEnv REDIRECT_STATUS 1'
  ))

  try {
    $configTestOutput = & $httpd -t -f $apacheConf 2>&1
    $configTestExitCode = $LASTEXITCODE
    Set-Content -Path (Join-Path $script:ScenarioRoot 'apache-configtest.log') -Value (($configTestOutput | Out-String).TrimEnd())
    if ($configTestExitCode -ne 0) {
      Write-Host ($configTestOutput | Out-String)
      throw 'Apache configuration test failed'
    }

    $apacheProcess = Start-Process -FilePath $httpd -ArgumentList @('-X', '-f', $apacheConf) -WorkingDirectory $apacheRoot -RedirectStandardOutput $apacheStdout -RedirectStandardError $apacheStderr -PassThru
    $url = 'http://127.0.0.1:{0}/web-stress.php' -f $port
    Wait-ForHttpUrl -Url $url

    $results = Invoke-RepeatedCurlJson -NamePrefix 'apache-cgi-web-stress' -Url $url -Count 2
    Assert-RepeatedWebResults `
      -Results $results `
      -ExpectedLoaded $Config.ExpectedLoaded `
      -ExpectedSerializer $Config.SessionSerializer `
      -ExpectedSapi 'cgi-fcgi' `
      -ExpectedServerPattern 'Apache' `
      -ExpectedOpcacheLoaded $Config.ExpectOpcacheLoaded `
      -ExpectedOpcacheEnabled $Config.ExpectWebOpcacheEnabled `
      -ExpectedJit $Config.ExpectedJitValue `
      -Label 'Apache CGI'
  } catch {
    foreach ($path in @($apacheStdout, $apacheStderr, $apacheErrorLog, $apacheAccessLog)) {
      if (Test-Path $path) {
        Write-Host ("--- {0}" -f $path)
        Get-Content -Path $path -ErrorAction SilentlyContinue | Write-Host
      }
    }
    throw
  } finally {
    if ($null -ne $apacheProcess -and -not $apacheProcess.HasExited) {
      Stop-Process -Id $apacheProcess.Id -Force
    }
  }
}

function Invoke-ApacheFcgidWebSmoke {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Config,

    [Parameter(Mandatory = $true)]
    [string]$WebRoot
  )

  $httpd = Ensure-ApacheInstalled
  $apacheRoot = Split-Path -Parent (Split-Path -Parent $httpd)
  $fcgidModulePath = Join-Path $apacheRoot 'modules\mod_fcgid.so'
  if (-not (Test-Path $fcgidModulePath)) {
    Write-Host 'Apache mod_fcgid is not available, skipping Apache FastCGI repro'
    return
  }

  $defaultConf = Join-Path $apacheRoot 'conf\httpd.conf'
  $defaultConfLines = Get-Content -Path $defaultConf
  $moduleLines = @($defaultConfLines | Where-Object { $_ -match '^\s*LoadModule ' })
  $requiredModulePatterns = @('alias_module', 'authz_core_module', 'env_module', 'fcgid_module')

  foreach ($modulePattern in $requiredModulePatterns) {
    if ($modulePattern -eq 'fcgid_module') {
      $moduleLines += 'LoadModule fcgid_module modules/mod_fcgid.so'
      continue
    }

    if (-not ($moduleLines | Where-Object { $_ -match ("LoadModule\s+{0}\s+" -f $modulePattern) })) {
      $line = $defaultConfLines | Where-Object { $_ -match ("^\s*#\s*LoadModule\s+{0}\s+" -f $modulePattern) } | Select-Object -First 1
      if ($null -eq $line) {
        throw "Could not find Apache module line for $modulePattern"
      }

      $moduleLines += ($line -replace '^\s*#\s*', '')
    }
  }

  $port = 8052
  $apacheConf = Join-Path $script:ScenarioRoot 'apache-fcgid-httpd.conf'
  $apachePid = Join-Path $script:ScenarioRoot 'apache-fcgid-httpd.pid'
  $apacheErrorLog = Join-Path $script:ScenarioRoot 'apache-fcgid-error.log'
  $apacheAccessLog = Join-Path $script:ScenarioRoot 'apache-fcgid-access.log'
  $apacheStdout = Join-Path $script:ScenarioRoot 'apache-fcgid-stdout.log'
  $apacheStderr = Join-Path $script:ScenarioRoot 'apache-fcgid-stderr.log'
  $wrapperPath = Join-Path $script:ScenarioRoot 'apache-fcgid-wrapper.cmd'
  $apacheProcess = $null
  $phpConfigDir = Convert-ToIniPath (Split-Path -Parent $Config.MainIni)
  $phpScanDir = Convert-ToIniPath $Config.ScanDir

  Write-TextFile -Path $wrapperPath -Lines @(
    '@echo off',
    ('set PHPRC={0}' -f $phpConfigDir),
    ('set PHP_INI_SCAN_DIR={0}' -f $phpScanDir),
    ('"{0}" -d cgi.force_redirect=0 -c "{1}"' -f $script:PhpCgi, $Config.MainIni)
  )

  Write-TextFile -Path $apacheConf -Lines (@(
    ('ServerRoot "{0}"' -f (Convert-ToIniPath $apacheRoot)),
    ('DefaultRuntimeDir "{0}"' -f (Convert-ToIniPath $script:ScenarioRoot)),
    ('Listen 127.0.0.1:{0}' -f $port),
    ('ServerName 127.0.0.1:{0}' -f $port),
    ('PidFile "{0}"' -f (Convert-ToIniPath $apachePid)),
    ('ErrorLog "{0}"' -f (Convert-ToIniPath $apacheErrorLog)),
    'LogLevel warn'
  ) + $moduleLines + @(
    ('TypesConfig "{0}"' -f (Convert-ToIniPath (Join-Path $apacheRoot 'conf\mime.types'))),
    ('DocumentRoot "{0}"' -f (Convert-ToIniPath $WebRoot)),
    '<Directory />',
    '  AllowOverride none',
    '  Require all denied',
    '</Directory>',
    ('<Directory "{0}">' -f (Convert-ToIniPath $WebRoot)),
    '  AllowOverride None',
    '  Options ExecCGI FollowSymLinks',
    '  Require all granted',
    '</Directory>',
    'LogFormat "%h %l %u %t \"%r\" %>s %b" common',
    ('CustomLog "{0}" common' -f (Convert-ToIniPath $apacheAccessLog)),
    'DirectoryIndex web-stress.php web-smoke.php',
    ('FcgidWrapper "{0}" .php' -f (Convert-ToIniPath $wrapperPath)),
    'AddHandler fcgid-script .php',
    'FcgidMaxProcesses 1',
    'FcgidMaxProcessesPerClass 1',
    'FcgidMinProcessesPerClass 1',
    'FcgidMaxRequestsPerProcess 1000',
    'FcgidIdleTimeout 3600'
  ))

  try {
    $configTestOutput = & $httpd -t -f $apacheConf 2>&1
    $configTestExitCode = $LASTEXITCODE
    Set-Content -Path (Join-Path $script:ScenarioRoot 'apache-fcgid-configtest.log') -Value (($configTestOutput | Out-String).TrimEnd())
    if ($configTestExitCode -ne 0) {
      Write-Host ($configTestOutput | Out-String)
      throw 'Apache FastCGI configuration test failed'
    }

    $apacheProcess = Start-Process -FilePath $httpd -ArgumentList @('-X', '-f', $apacheConf) -WorkingDirectory $apacheRoot -RedirectStandardOutput $apacheStdout -RedirectStandardError $apacheStderr -PassThru
    $url = 'http://127.0.0.1:{0}/web-stress.php' -f $port
    Wait-ForHttpUrl -Url $url

    $results = Invoke-RepeatedCurlJson -NamePrefix 'apache-fcgid-web-stress' -Url $url -Count $script:RepeatedRequestCount
    Assert-RepeatedWebResults `
      -Results $results `
      -ExpectedLoaded $Config.ExpectedLoaded `
      -ExpectedSerializer $Config.SessionSerializer `
      -ExpectedSapi 'cgi-fcgi' `
      -ExpectedServerPattern 'Apache' `
      -ExpectedOpcacheLoaded $Config.ExpectOpcacheLoaded `
      -ExpectedOpcacheEnabled $Config.ExpectWebOpcacheEnabled `
      -ExpectedJit $Config.ExpectedJitValue `
      -ExpectStablePid $true `
      -Label 'Apache FastCGI'
  } catch {
    foreach ($path in @($apacheStdout, $apacheStderr, $apacheErrorLog, $apacheAccessLog)) {
      if (Test-Path $path) {
        Write-Host ("--- {0}" -f $path)
        Get-Content -Path $path -ErrorAction SilentlyContinue | Write-Host
      }
    }
    throw
  } finally {
    if ($null -ne $apacheProcess -and -not $apacheProcess.HasExited) {
      Stop-Process -Id $apacheProcess.Id -Force
    }
  }
}

function Invoke-BuiltinServerSmoke {
  param(
    [Parameter(Mandatory = $true)]
    [pscustomobject]$Config,

    [Parameter(Mandatory = $true)]
    [string]$WebRoot
  )

  $port = 8060
  $serverStdout = Join-Path $script:ScenarioRoot 'builtin-server-stdout.log'
  $serverStderr = Join-Path $script:ScenarioRoot 'builtin-server-stderr.log'
  $serverProcess = $null
  $previousScanDir = Get-EnvValue -Name 'PHP_INI_SCAN_DIR'
  $url = 'http://127.0.0.1:{0}/web-stress.php' -f $port

  try {
    Set-Item Env:PHP_INI_SCAN_DIR -Value $Config.ScanDir
    $serverProcess = Start-Process -FilePath $script:PhpExe -ArgumentList @('-S', ('127.0.0.1:{0}' -f $port), '-t', $WebRoot, '-c', $Config.MainIni) -WorkingDirectory $WebRoot -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr -PassThru
  } finally {
    Restore-EnvValue -Name 'PHP_INI_SCAN_DIR' -Value $previousScanDir
  }

  try {
    Wait-ForHttpUrl -Url $url

    $results = Invoke-RepeatedCurlJson -NamePrefix 'builtin-web-stress' -Url $url -Count $script:RepeatedRequestCount
    Assert-RepeatedWebResults `
      -Results $results `
      -ExpectedLoaded $Config.ExpectedLoaded `
      -ExpectedSerializer $Config.SessionSerializer `
      -ExpectedSapi 'cli-server' `
      -ExpectedOpcacheLoaded $Config.ExpectOpcacheLoaded `
      -ExpectedOpcacheEnabled $Config.ExpectBuiltinOpcacheEnabled `
      -ExpectedJit $Config.ExpectedJitValue `
      -ExpectStablePid $true `
      -Label 'built-in server'
  } catch {
    foreach ($path in @($serverStdout, $serverStderr)) {
      if (Test-Path $path) {
        Write-Host ("--- {0}" -f $path)
        Get-Content -Path $path -ErrorAction SilentlyContinue | Write-Host
      }
    }
    throw
  } finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
      Stop-Process -Id $serverProcess.Id -Force
    }
  }
}

function Get-OpcacheProfileSettings {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('disabled', 'tracing-default', 'tracing-cli-hot', '1254-hot', '1205-hot')]
    [string]$Profile,

    [Parameter(Mandatory = $true)]
    [string]$ErrorLogPath
  )

  $opcacheDllPath = Join-Path $script:ExtDir 'php_opcache.dll'
  $opcacheBundled = -not (Test-Path $opcacheDllPath)

  if ($Profile -eq 'disabled') {
    return [pscustomobject]@{
      IniLines = @()
      ExpectOpcacheLoaded = $null
      ExpectWebOpcacheEnabled = $null
      ExpectBuiltinOpcacheEnabled = $null
      ExpectedJitValue = $null
    }
  }

  $enableCli = if ($Profile -eq 'tracing-default') { 0 } else { 1 }
  $jitValue = switch ($Profile) {
    'tracing-default' { 'tracing' }
    'tracing-cli-hot' { 'tracing' }
    '1254-hot' { '1254' }
    '1205-hot' { '1205' }
    default { throw "Unsupported opcache profile: $Profile" }
  }
  $hotJit = $Profile -ne 'tracing-default'

  $iniLines = @(
    ('extension_dir="{0}"' -f (Convert-ToIniPath $script:ExtDir))
  )

  if (-not $opcacheBundled) {
    $iniLines += 'zend_extension=php_opcache.dll'
  }

  $iniLines += @(
    'opcache.enable=1',
    ('opcache.enable_cli={0}' -f $enableCli),
    'opcache.jit_buffer_size=100M',
    ('opcache.jit={0}' -f $jitValue),
    'opcache.validate_timestamps=1',
    'opcache.revalidate_freq=10',
    'opcache.enable_file_override=1',
    'opcache.memory_consumption=64',
    'opcache.max_accelerated_files=3000',
    'opcache.max_wasted_percentage=10',
    'opcache.interned_strings_buffer=16',
    ('opcache.error_log="{0}"' -f $ErrorLogPath),
    'opcache.log_verbosity_level=4'
  )

  if ($hotJit) {
    $iniLines += @(
      'opcache.jit_hot_func=1',
      'opcache.jit_hot_loop=1',
      'opcache.jit_hot_return=1',
      'opcache.jit_hot_side_exit=1'
    )
  }

  return [pscustomobject]@{
    IniLines = $iniLines
    ExpectOpcacheLoaded = $true
    ExpectWebOpcacheEnabled = $true
    ExpectBuiltinOpcacheEnabled = $(if ($Profile -eq 'tracing-default') { $null } else { [bool]$enableCli })
    ExpectedJitValue = $jitValue
  }
}

function New-ReproductionConfig {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('legacy', 'updated')]
    [string]$Mode,

    [ValidateSet('disabled', 'tracing-default', 'tracing-cli-hot', '1254-hot', '1205-hot')]
    [string]$OpcacheProfile = 'disabled'
  )

  $configRoot = Join-Path $script:ScenarioRoot $Mode
  $scanDir = Join-Path $configRoot 'scan'
  $mainIni = Join-Path $configRoot 'php.ini'
  $errorLog = Convert-ToIniPath (Join-Path $script:ScenarioRoot ("{0}-php-error.log" -f $Mode))
  $opcacheErrorLog = Convert-ToIniPath (Join-Path $script:ScenarioRoot ("{0}-opcache.log" -f $Mode))
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
  $opcacheSettings = Get-OpcacheProfileSettings -Profile $OpcacheProfile -ErrorLogPath $opcacheErrorLog

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

    if ($opcacheSettings.IniLines.Count -gt 0) {
      Write-TextFile -Path (Join-Path $scanDir '00_opcache.ini') -Lines $opcacheSettings.IniLines
    }

    return [pscustomobject]@{
      MainIni = $mainIni
      ScanDir = $scanDir
      ExpectedLoaded = @()
      ExpectedMissing = @('curl', 'intl', 'mbstring', 'openssl', 'redis', 'igbinary', 'pgsql', 'pdo_pgsql', 'soap')
      SessionSerializer = 'php'
      ExpectOpcacheLoaded = $opcacheSettings.ExpectOpcacheLoaded
      ExpectWebOpcacheEnabled = $opcacheSettings.ExpectWebOpcacheEnabled
      ExpectBuiltinOpcacheEnabled = $opcacheSettings.ExpectBuiltinOpcacheEnabled
      ExpectedJitValue = $opcacheSettings.ExpectedJitValue
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

  if ($opcacheSettings.IniLines.Count -gt 0) {
    Write-TextFile -Path (Join-Path $scanDir '00_opcache.ini') -Lines $opcacheSettings.IniLines
  }

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
    ExpectOpcacheLoaded = $opcacheSettings.ExpectOpcacheLoaded
    ExpectWebOpcacheEnabled = $opcacheSettings.ExpectWebOpcacheEnabled
    ExpectBuiltinOpcacheEnabled = $opcacheSettings.ExpectBuiltinOpcacheEnabled
    ExpectedJitValue = $opcacheSettings.ExpectedJitValue
  }
}

$script:ArtifactRoot = Join-Path $env:RUNNER_TEMP 'issue-21697-comment'
$script:ScenarioRoot = Join-Path $script:ArtifactRoot ("{0}-{1}-{2}" -f $PhpVersionUnderTest, $ConfigMode, $OpcacheProfile)
New-Item -ItemType Directory -Path $script:ScenarioRoot -Force | Out-Null
$script:RepeatedRequestCount = 6

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

$config = New-ReproductionConfig -Mode $ConfigMode -OpcacheProfile $OpcacheProfile
$webRoot = Join-Path $script:ScenarioRoot 'webroot'
New-Item -ItemType Directory -Path $webRoot -Force | Out-Null

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

$webSmokeScript = Join-Path $webRoot 'web-smoke.php'
Write-TextFile -Path $webSmokeScript -Lines @(
  '<?php',
  'error_reporting(E_ALL);',
  'ini_set("display_errors", "1");',
  'header("Content-Type: application/json");',
  '',
  '$trackedExtensions = ["curl", "intl", "mbstring", "openssl", "redis", "igbinary", "pgsql", "pdo_pgsql", "soap"];',
  '$opcacheStatus = function_exists("opcache_get_status") ? @opcache_get_status(false) : false;',
  '$result = [',
  '    "php_version" => PHP_VERSION,',
  '    "sapi" => PHP_SAPI,',
  '    "server_software" => $_SERVER["SERVER_SOFTWARE"] ?? "",',
  '    "gateway_interface" => $_SERVER["GATEWAY_INTERFACE"] ?? "",',
  '    "request_uri" => $_SERVER["REQUEST_URI"] ?? "",',
  '    "pid" => getmypid(),',
  '    "opcache_loaded" => function_exists("opcache_get_status"),',
  '    "opcache_enabled" => is_array($opcacheStatus) ? (bool) ($opcacheStatus["opcache_enabled"] ?? false) : false,',
  '    "opcache_jit" => (string) ini_get("opcache.jit"),',
  '    "opcache_jit_on" => is_array($opcacheStatus) ? (bool) ($opcacheStatus["jit"]["on"] ?? false) : false,',
  '    "loaded_tracked_extensions" => array_values(array_filter($trackedExtensions, "extension_loaded")),',
  '    "session_save_handler" => ini_get("session.save_handler"),',
  '    "session_save_path" => ini_get("session.save_path"),',
  '    "session_serialize_handler" => ini_get("session.serialize_handler"),',
  '];',
  '',
  'echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;'
)

$stressLibRoot = Join-Path $webRoot 'stress-lib'
New-Item -ItemType Directory -Path $stressLibRoot -Force | Out-Null
$stressClasses = @()

for ($index = 0; $index -lt 24; $index++) {
  $className = 'StressWorker{0:D2}' -f $index
  $stressClasses += $className
  Write-TextFile -Path (Join-Path $stressLibRoot ("{0}.php" -f $className)) -Lines @(
    '<?php',
    "final class $className {",
    '    public static function crunch(int $seed, int $round): int {',
    '        $value = $seed ^ ($round << 2);',
    '        for ($i = 0; $i < 320; $i++) {',
    '            $value += (($i * 17) ^ ($seed + $round)) % 97;',
    '            $value ^= (($value << 5) | ($value >> 3));',
    '            $value &= 0x7fffffff;',
    '        }',
    '        return $value;',
    '    }',
    '}'
  )
}

$bootstrapLines = @('<?php')
foreach ($className in $stressClasses) {
  $bootstrapLines += ('require_once __DIR__ . "/{0}.php";' -f $className)
}
$bootstrapLines += ''
$bootstrapLines += 'return ['
foreach ($className in $stressClasses) {
  $bootstrapLines += ("    '{0}'," -f $className)
}
$bootstrapLines += '];'
Write-TextFile -Path (Join-Path $stressLibRoot 'bootstrap.php') -Lines $bootstrapLines

$webStressScript = Join-Path $webRoot 'web-stress.php'
Write-TextFile -Path $webStressScript -Lines @(
  '<?php',
  'error_reporting(E_ALL);',
  'ini_set("display_errors", "1");',
  'header("Content-Type: application/json");',
  '',
  '$trackedExtensions = ["curl", "intl", "mbstring", "openssl", "redis", "igbinary", "pgsql", "pdo_pgsql", "soap"];',
  '$classes = require __DIR__ . "/stress-lib/bootstrap.php";',
  '',
  'function stress_mix(int $seed, int $offset): int {',
  '    $value = $seed + ($offset * 13);',
  '    for ($i = 0; $i < 256; $i++) {',
  '        $value ^= (($value << 7) | ($value >> 2));',
  '        $value += ($offset ^ $i) % 19;',
  '        $value &= 0x7fffffff;',
  '    }',
  '    return $value;',
  '}',
  '',
  '$requestNumber = (int) ($_GET["request"] ?? 0);',
  '',
  '$checksum = 0;',
  'for ($round = 0; $round < 180; $round++) {',
  '    foreach ($classes as $className) {',
  '        $checksum = ($checksum + $className::crunch($round + $requestNumber + 1, $round)) & 0x7fffffff;',
  '    }',
  '}',
  '',
  '$payload = [];',
  'for ($offset = 0; $offset < 256; $offset++) {',
  '    $payload[] = stress_mix($checksum, $offset);',
  '}',
  'sort($payload);',
  '',
  '$opcacheStatus = function_exists("opcache_get_status") ? @opcache_get_status(false) : false;',
  '$result = [',
  '    "php_version" => PHP_VERSION,',
  '    "sapi" => PHP_SAPI,',
  '    "server_software" => $_SERVER["SERVER_SOFTWARE"] ?? "",',
  '    "gateway_interface" => $_SERVER["GATEWAY_INTERFACE"] ?? "",',
  '    "request_uri" => $_SERVER["REQUEST_URI"] ?? "",',
  '    "pid" => getmypid(),',
  '    "opcache_loaded" => function_exists("opcache_get_status"),',
  '    "opcache_enabled" => is_array($opcacheStatus) ? (bool) ($opcacheStatus["opcache_enabled"] ?? false) : false,',
  '    "opcache_jit" => (string) ini_get("opcache.jit"),',
  '    "opcache_jit_on" => is_array($opcacheStatus) ? (bool) ($opcacheStatus["jit"]["on"] ?? false) : false,',
  '    "opcache_num_cached_scripts" => is_array($opcacheStatus) ? (int) ($opcacheStatus["opcache_statistics"]["num_cached_scripts"] ?? 0) : 0,',
  '    "script_cached" => function_exists("opcache_is_script_cached") ? @opcache_is_script_cached(__FILE__) : false,',
  '    "loaded_tracked_extensions" => array_values(array_filter($trackedExtensions, "extension_loaded")),',
  '    "session_save_handler" => ini_get("session.save_handler"),',
  '    "session_save_path" => ini_get("session.save_path"),',
  '    "session_serialize_handler" => ini_get("session.serialize_handler"),',
  '    "request_number" => $requestNumber,',
  '    "workload_checksum" => $checksum,',
  '];',
  '',
  'echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;'
)

$jitStressScript = Join-Path $script:ScenarioRoot 'jit-stress.php'
Write-TextFile -Path $jitStressScript -Lines @(
  '<?php',
  'error_reporting(E_ALL);',
  'ini_set("display_errors", "1");',
  '',
  '$trackedExtensions = ["curl", "intl", "mbstring", "openssl", "redis", "igbinary", "pgsql", "pdo_pgsql", "soap"];',
  '$classes = require __DIR__ . "/webroot/stress-lib/bootstrap.php";',
  '',
  'function jit_stress_mix(int $seed, int $offset): int {',
  '    $value = $seed + ($offset * 29);',
  '    for ($i = 0; $i < 512; $i++) {',
  '        $value ^= (($value << 6) | ($value >> 4));',
  '        $value += ($offset ^ $i) % 23;',
  '        $value &= 0x7fffffff;',
  '    }',
  '    return $value;',
  '}',
  '',
  '$checksum = 0;',
  'for ($round = 0; $round < 220; $round++) {',
  '    foreach ($classes as $className) {',
  '        $checksum = ($checksum + $className::crunch($round + 7, $round)) & 0x7fffffff;',
  '    }',
  '}',
  '',
  '$payload = [];',
  'for ($offset = 0; $offset < 384; $offset++) {',
  '    $payload[] = jit_stress_mix($checksum, $offset);',
  '}',
  '',
  '$opcacheStatus = function_exists("opcache_get_status") ? @opcache_get_status(false) : false;',
  '$result = [',
  '    "php_version" => PHP_VERSION,',
  '    "sapi" => PHP_SAPI,',
  '    "pid" => getmypid(),',
  '    "opcache_loaded" => function_exists("opcache_get_status"),',
  '    "opcache_enabled" => is_array($opcacheStatus) ? (bool) ($opcacheStatus["opcache_enabled"] ?? false) : false,',
  '    "opcache_jit" => (string) ini_get("opcache.jit"),',
  '    "opcache_jit_on" => is_array($opcacheStatus) ? (bool) ($opcacheStatus["jit"]["on"] ?? false) : false,',
  '    "workload_checksum" => $checksum,',
  '    "loaded_tracked_extensions" => array_values(array_filter($trackedExtensions, "extension_loaded")),',
  '    "session_save_handler" => ini_get("session.save_handler"),',
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
$cliJitStress = Invoke-PhpCommand -Name 'php-cli-jit-stress' -Binary $script:PhpExe -Arguments @('-c', $config.MainIni, $jitStressScript) -ScanDir $config.ScanDir
$cgiJitStress = Invoke-PhpCommand -Name 'php-cgi-jit-stress' -Binary $script:PhpCgi -Arguments @('-q', '-c', $config.MainIni, '-f', $jitStressScript) -ScanDir $config.ScanDir
Invoke-BuiltinServerSmoke -Config $config -WebRoot $webRoot

if ($WebMode -eq 'full') {
  Invoke-IisWebSmoke -Config $config -WebRoot $webRoot
  Invoke-ApacheCgiWebSmoke -Config $config -WebRoot $webRoot
  Invoke-ApacheFcgidWebSmoke -Config $config -WebRoot $webRoot
}

$summaryLines = @(
  "### PHP $PhpVersionUnderTest / $ConfigMode / $OpcacheProfile / $WebMode",
  '',
  '- `php.exe` and `php-cgi.exe` both started successfully with the reconstructed config.',
  '- The built-in PHP server handled repeated stress requests and was validated with `curl`.',
  ('- Expected loaded extensions: `{0}`' -f $(if ($config.ExpectedLoaded.Count -eq 0) { 'none' } else { $config.ExpectedLoaded -join ', ' })),
  ('- Expected missing extensions: `{0}`' -f $(if ($config.ExpectedMissing.Count -eq 0) { 'none' } else { $config.ExpectedMissing -join ', ' })),
  ('- CLI smoke output saved to `{0}`.' -f (Join-Path $script:ScenarioRoot 'php-cli-extension-smoke.log')),
  ('- CGI smoke output saved to `{0}`.' -f (Join-Path $script:ScenarioRoot 'php-cgi-extension-smoke.log')),
  ('- Direct CLI JIT stress output saved to `{0}`.' -f (Join-Path $script:ScenarioRoot 'php-cli-jit-stress.log')),
  ('- Direct CGI JIT stress output saved to `{0}`.' -f (Join-Path $script:ScenarioRoot 'php-cgi-jit-stress.log')),
  ('- Built-in server stress outputs are saved with the `builtin-web-stress-*.log` prefix in `{0}`.' -f $script:ScenarioRoot)
)

if ($WebMode -eq 'full') {
  $summaryLines += '- IIS FastCGI handled repeated stress requests through a single backend process.'
  $summaryLines += '- Apache CGI and Apache FastCGI both served the stress endpoint through `php-cgi.exe`.'
  $summaryLines += ('- IIS stress outputs are saved with the `iis-web-stress-*.log` prefix in `{0}`.' -f $script:ScenarioRoot)
  $summaryLines += ('- Apache CGI stress outputs are saved with the `apache-cgi-web-stress-*.log` prefix in `{0}`.' -f $script:ScenarioRoot)
  $summaryLines += ('- Apache FastCGI stress outputs are saved with the `apache-fcgid-web-stress-*.log` prefix in `{0}`.' -f $script:ScenarioRoot)
}

Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($summaryLines -join [Environment]::NewLine)

Write-Host 'CLI smoke result:'
Write-Host $cliSmoke
Write-Host 'CGI smoke result:'
Write-Host $cgiSmoke
Write-Host 'CLI JIT stress result:'
Write-Host $cliJitStress
Write-Host 'CGI JIT stress result:'
Write-Host $cgiJitStress
