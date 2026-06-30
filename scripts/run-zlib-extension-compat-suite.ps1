param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('source', 'pecl')]
  [string] $Mode,

  [Parameter(Mandatory = $true)]
  [string] $PhpArtifactsDirectory,

  [Parameter(Mandatory = $false)]
  [string] $ExtensionArtifactsDirectory = '',

  [Parameter(Mandatory = $true)]
  [string] $ReportsDirectory,

  [Parameter(Mandatory = $true)]
  [string] $PhpTarget,

  [Parameter(Mandatory = $true)]
  [string] $PhpRunId,

  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'x86')]
  [string] $Arch,

  [Parameter(Mandatory = $true)]
  [ValidateSet('nts', 'ts')]
  [string] $Ts,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^v[sc]\d+$')]
  [string] $Vs,

  [Parameter(Mandatory = $false)]
  [string] $AllowedMissingPackages = '',

  [Parameter(Mandatory = $false)]
  [string] $AllowedExternalPeclLoadFailures = '',

  [Parameter(Mandatory = $false)]
  [switch] $AllowMissingPackages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExtensionMetadata = @(
  [PSCustomObject]@{ Package = 'memcache';   Artifact = 'memcache';   Module = 'memcache';   Ini = 'extension';      Required = $true;  Dependencies = @();        LoadBefore = @() },
  [PSCustomObject]@{ Package = 'memcached';  Artifact = 'memcached';  Module = 'memcached';  Ini = 'extension';      Required = $true;  Dependencies = @();        LoadBefore = @() },
  [PSCustomObject]@{ Package = 'oauth';      Artifact = 'oauth';      Module = 'OAuth';      Ini = 'extension';      Required = $true;  Dependencies = @();        LoadBefore = @() },
  [PSCustomObject]@{ Package = 'xdebug';     Artifact = 'xdebug';     Module = 'xdebug';     Ini = 'zend_extension'; Required = $true;  Dependencies = @();        LoadBefore = @() },
  [PSCustomObject]@{ Package = 'pecl_http';  Artifact = 'http';       Module = 'http';       Ini = 'extension';      Required = $true;  Dependencies = @('raphf'); LoadBefore = @('iconv', 'raphf', 'lexbor') },
  [PSCustomObject]@{ Package = 'solr';       Artifact = 'solr';       Module = 'solr';       Ini = 'extension';      Required = $true;  Dependencies = @();        LoadBefore = @() },
  [PSCustomObject]@{ Package = 'ssh2';       Artifact = 'ssh2';       Module = 'ssh2';       Ini = 'extension';      Required = $true;  Dependencies = @();        LoadBefore = @() },
  [PSCustomObject]@{ Package = 'xlswriter';  Artifact = 'xlswriter';  Module = 'xlswriter';  Ini = 'extension';      Required = $true;  Dependencies = @();        LoadBefore = @() },
  [PSCustomObject]@{ Package = 'zip';        Artifact = 'zip';        Module = 'zip';        Ini = 'extension';      Required = $true;  Dependencies = @();        LoadBefore = @() }
)

$DependencyMetadata = @{
  raphf = [PSCustomObject]@{ Package = 'raphf'; Artifact = 'raphf'; Module = 'raphf'; Ini = 'extension'; Required = $false; Dependencies = @(); LoadBefore = @() }
}

function Resolve-FullPath([string] $Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ''
  }
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Expand-Zip {
  param(
    [Parameter(Mandatory = $true)][string] $Zip,
    [Parameter(Mandatory = $true)][string] $Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  try {
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
  } catch {
    $output = & 7z x $Zip "-o$Destination" -y 2>&1
    $exitCode = $LASTEXITCODE
    $output | Out-Host
    if ($exitCode -gt 1) {
      throw "7z failed extracting $Zip with exit code $exitCode"
    }
  }
}

function Get-PhpArtifactZip {
  param(
    [Parameter(Mandatory = $true)][string] $ArtifactsDirectory,
    [Parameter(Mandatory = $true)][string] $Arch,
    [Parameter(Mandatory = $true)][string] $Ts
  )

  $zipRegex = "^php-(?<version>.+?)-(?<nts>nts-)?Win32-v[sc]\d+-$([regex]::Escape($Arch))\.zip$"
  $zips = @(
    Get-ChildItem -LiteralPath $ArtifactsDirectory -Recurse -Filter 'php-*.zip' -File |
      Where-Object {
        $match = [regex]::Match($_.Name, $zipRegex)
        $_.Name -notmatch '^php-(?:debug|devel|test)-pack-' -and
        $match.Success -and
        (($Ts -eq 'nts') -eq $match.Groups['nts'].Success)
      } |
      Sort-Object Name
  )

  if ($zips.Count -ne 1) {
    $found = (Get-ChildItem -LiteralPath $ArtifactsDirectory -Recurse -Filter '*.zip' -File | ForEach-Object Name | Sort-Object) -join ', '
    throw "Expected one PHP runtime artifact for arch=$Arch ts=$Ts, found $($zips.Count). Available: $found"
  }

  return $zips[0]
}

function Get-PhpSeries {
  param([Parameter(Mandatory = $true)][string] $PhpTarget)

  if ($PhpTarget -eq 'master') {
    return '8.6'
  }
  if ($PhpTarget -match '^\d+\.\d+') {
    return $Matches[0]
  }
  throw "Cannot derive PHP series from '$PhpTarget'"
}

function Get-NaturalVersionKey {
  param([Parameter(Mandatory = $true)][string] $Version)

  $parts = [regex]::Matches($Version, '\d+|[A-Za-z]+') | ForEach-Object {
    $token = $_.Value
    if ($token -match '^\d+$') {
      return ('{0:D8}' -f [int]$token)
    }
    return $token.ToLowerInvariant()
  }
  return ($parts -join '.')
}

function Get-WindowsPeclPackageUrl {
  param(
    [Parameter(Mandatory = $true)][string] $Package,
    [Parameter(Mandatory = $true)][string] $Artifact,
    [Parameter(Mandatory = $true)][string] $PhpSeries,
    [Parameter(Mandatory = $true)][string] $Ts,
    [Parameter(Mandatory = $true)][string] $Vs,
    [Parameter(Mandatory = $true)][string] $Arch
  )

  $baseUrl = "https://downloads.php.net/~windows/pecl/releases/$Package"
  $artifactPrefixes = Get-UniqueOrderedStrings -Values @($Package, $Artifact)
  try {
    $index = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing
  } catch {
    return $null
  }

  $versions = @(
    [regex]::Matches($index.Content, 'href="([^"/]+)/"') |
      ForEach-Object { $_.Groups[1].Value } |
      Where-Object { $_ -match '^\d' } |
      Sort-Object @{ Expression = { Get-NaturalVersionKey $_ }; Descending = $true }
  )

  $tsPart = if ($Ts -eq 'nts') { 'nts' } else { 'ts' }
  foreach ($version in $versions) {
    $versionUrl = "$baseUrl/$version/"
    try {
      $versionIndex = Invoke-WebRequest -Uri $versionUrl -UseBasicParsing
    } catch {
      continue
    }
    foreach ($prefix in $artifactPrefixes) {
      $pattern = "php_$([regex]::Escape($prefix))-$([regex]::Escape($version))-$([regex]::Escape($PhpSeries))-$tsPart-$([regex]::Escape($Vs))-$([regex]::Escape($Arch))\.zip"
      $match = [regex]::Match($versionIndex.Content, $pattern)
      if ($match.Success) {
        return "$versionUrl$($match.Value)"
      }
    }
  }

  return $null
}

function Save-WebFile {
  param(
    [Parameter(Mandatory = $true)][string] $Url,
    [Parameter(Mandatory = $true)][string] $Destination
  )

  Invoke-WebRequest -Uri $Url -UseBasicParsing -OutFile $Destination
  if (!(Test-Path -LiteralPath $Destination -PathType Leaf)) {
    throw "Download did not create $Destination from $Url"
  }
}

function Install-ExtensionPackage {
  param(
    [Parameter(Mandatory = $true)][string] $PackageZip,
    [Parameter(Mandatory = $true)][string] $ExtractRoot,
    [Parameter(Mandatory = $true)][string] $PhpDirectory,
    [Parameter(Mandatory = $true)][string] $ExtensionDirectory
  )

  $packageName = [System.IO.Path]::GetFileNameWithoutExtension($PackageZip)
  $packageDir = Join-Path $ExtractRoot $packageName
  if (Test-Path -LiteralPath $packageDir) {
    Remove-Item -LiteralPath $packageDir -Recurse -Force
  }
  Expand-Zip -Zip $PackageZip -Destination $packageDir

  $dlls = @(Get-ChildItem -LiteralPath $packageDir -Recurse -Filter '*.dll' -File | Sort-Object Name)
  if ($dlls.Count -eq 0) {
    throw "No DLLs found in extension package $PackageZip"
  }

  foreach ($dll in $dlls) {
    if ($dll.Name -like 'php_*.dll') {
      Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $ExtensionDirectory $dll.Name) -Force
    } else {
      Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $PhpDirectory $dll.Name) -Force
    }
  }

  Get-ChildItem -LiteralPath $packageDir -Recurse -Include '*.pdb', '*.xml', '*.ini' -File -ErrorAction SilentlyContinue |
    ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $PhpDirectory $_.Name) -Force
    }

  return $dlls
}

function Find-SourceExtensionZip {
  param(
    [Parameter(Mandatory = $true)][string] $ArtifactsDirectory,
    [Parameter(Mandatory = $true)][string] $Package,
    [Parameter(Mandatory = $true)][string] $Artifact,
    [Parameter(Mandatory = $true)][string] $PhpTarget,
    [Parameter(Mandatory = $true)][string] $Ts,
    [Parameter(Mandatory = $true)][string] $Vs,
    [Parameter(Mandatory = $true)][string] $Arch
  )

  $prefixes = @($Package, $Artifact) | Sort-Object -Unique | ForEach-Object { [regex]::Escape($_) }
  $prefixPattern = $prefixes -join '|'
  $pattern = "^php_($prefixPattern)-.+-$([regex]::Escape($PhpTarget))-$([regex]::Escape($Ts))-$([regex]::Escape($Vs))-$([regex]::Escape($Arch))\.zip$"
  $zips = @(
    Get-ChildItem -LiteralPath $ArtifactsDirectory -Recurse -Filter 'php_*.zip' -File |
      Where-Object { $_.Name -match $pattern -and $_.FullName -notmatch '[\\/]logs[\\/]' } |
      Sort-Object Name
  )
  if ($zips.Count -ne 1) {
    $found = (Get-ChildItem -LiteralPath $ArtifactsDirectory -Recurse -Filter 'php_*.zip' -File | ForEach-Object Name | Sort-Object) -join ', '
    throw "Expected one source-built package for $Package php=$PhpTarget arch=$Arch ts=$Ts vs=$Vs, found $($zips.Count). Available: $found"
  }
  return $zips[0].FullName
}

function Add-IniLine {
  param(
    [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]] $Lines,
    [Parameter(Mandatory = $true)][string] $Line
  )

  if (!$Lines.Contains($Line)) {
    $Lines.Add($Line)
  }
}

function Get-PhpExtensionDllPath {
  param(
    [Parameter(Mandatory = $true)][string] $ExtensionDirectory,
    [Parameter(Mandatory = $true)][string] $Module
  )

  $dllName = if ($Module -eq 'OAuth') { 'php_oauth.dll' } else { "php_$($Module.ToLowerInvariant()).dll" }
  return Join-Path $ExtensionDirectory $dllName
}

function Get-UniqueOrderedStrings {
  param([Parameter(Mandatory = $true)][string[]] $Values)

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $ordered = New-Object 'System.Collections.Generic.List[string]'
  foreach ($value in $Values) {
    if (![string]::IsNullOrWhiteSpace($value) -and $seen.Add($value)) {
      $ordered.Add($value)
    }
  }
  return @($ordered)
}

function Test-DllPresent {
  param(
    [Parameter(Mandatory = $true)][string] $DllName,
    [Parameter(Mandatory = $true)][string[]] $SearchDirectories
  )

  foreach ($directory in $SearchDirectories) {
    if (Test-Path -LiteralPath (Join-Path $directory $DllName) -PathType Leaf) {
      return $true
    }
  }
  return $false
}

function Get-PhpSdkIcuUrl {
  param(
    [Parameter(Mandatory = $true)][string] $IcuVersion,
    [Parameter(Mandatory = $true)][string] $Arch,
    [Parameter(Mandatory = $true)][string] $Vs
  )

  $trunk = 'https://downloads.php.net'
  $urls = @(
    "$trunk/~windows/php-sdk/deps/$Vs/$Arch/",
    "$trunk/~windows/php-sdk/deps/archives/$Vs/$Arch/"
  )
  foreach ($url in $urls) {
    try {
      $index = Invoke-WebRequest -Uri $url -UseBasicParsing
    } catch {
      continue
    }
    $match = [regex]::Match($index.Content, "href=`"([^`"]*ICU-$([regex]::Escape($IcuVersion))[^`"]*\.zip)`"")
    if ($match.Success) {
      $href = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
      return ([System.Uri]::new([System.Uri]$url, $href)).AbsoluteUri
    }
  }

  return ''
}

function Repair-HttpIcuDependencies {
  param(
    [Parameter(Mandatory = $true)][string] $PhpDirectory,
    [Parameter(Mandatory = $true)][string] $ExtensionDirectory,
    [Parameter(Mandatory = $true)][string] $Arch,
    [Parameter(Mandatory = $true)][string] $Vs,
    [Parameter(Mandatory = $true)][string] $RunReport
  )

  $httpDll = Get-PhpExtensionDllPath -ExtensionDirectory $ExtensionDirectory -Module 'http'
  if (!(Test-Path -LiteralPath $httpDll -PathType Leaf)) {
    return
  }

  $bytes = [System.IO.File]::ReadAllBytes($httpDll)
  $text = [System.Text.Encoding]::ASCII.GetString($bytes)
  $icuImports = @(Get-UniqueOrderedStrings -Values @(
    [regex]::Matches($text, 'icu[a-z]+(?<version>\d+)\.dll') |
      ForEach-Object { $_.Value }
  ))
  if ($icuImports.Count -eq 0) {
    return
  }

  $missingIcu = @(
    $icuImports |
      Where-Object { !(Test-DllPresent -DllName $_ -SearchDirectories @($PhpDirectory, $ExtensionDirectory)) }
  )
  if ($missingIcu.Count -eq 0) {
    return
  }

  $icuVersion = ([regex]::Match($missingIcu[0], '\d+')).Value
  $icuUrl = Get-PhpSdkIcuUrl -IcuVersion $icuVersion -Arch $Arch -Vs $Vs
  if ([string]::IsNullOrWhiteSpace($icuUrl)) {
    throw "Could not find PHP SDK ICU dependency package for ICU $icuVersion $Vs $Arch required by php_http.dll"
  }

  $icuRoot = Join-Path $PhpDirectory 'icu'
  if (Test-Path -LiteralPath $icuRoot) {
    Remove-Item -LiteralPath $icuRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $icuRoot | Out-Null
  $icuZip = Join-Path $icuRoot 'icu.zip'
  Save-WebFile -Url $icuUrl -Destination $icuZip
  Expand-Zip -Zip $icuZip -Destination $icuRoot

  $icuDlls = @(
    Get-ChildItem -LiteralPath $icuRoot -Recurse -Filter '*.dll' -File |
      Where-Object { $_.FullName -match '[\\/]bin[\\/]' } |
      Sort-Object Name
  )
  if ($icuDlls.Count -eq 0) {
    throw "No ICU DLLs were found in $icuUrl"
  }
  foreach ($dll in $icuDlls) {
    Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $PhpDirectory $dll.Name) -Force
  }

  "repaired_icu=$icuUrl" | Add-Content -LiteralPath $RunReport -Encoding ASCII
}

function Test-MissingPackageAllowed {
  param([Parameter(Mandatory = $true)][string] $Package)

  if ($AllowMissingPackages) {
    return $true
  }

  return Test-PackageListed -Package $Package
}

function Test-PackageListed {
  param([Parameter(Mandatory = $true)][string] $Package)

  $allowed = @(
    $AllowedMissingPackages -split ',' |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' }
  )
  return $allowed -contains $Package
}

function Test-ExternalPeclLoadFailureAllowed {
  param(
    [Parameter(Mandatory = $true)][string] $Module,
    [Parameter(Mandatory = $true)][string] $Package,
    [Parameter(Mandatory = $true)][string] $Artifact
  )

  if ($Mode -ne 'pecl') {
    return $false
  }

  $allowed = @(
    $AllowedExternalPeclLoadFailures -split ',' |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' }
  )

  return ($allowed -contains $Module -or $allowed -contains $Package -or $allowed -contains $Artifact)
}

function Invoke-MemcachedCommand {
  param(
    [Parameter(Mandatory = $true)][string] $HostName,
    [Parameter(Mandatory = $true)][int] $Port,
    [Parameter(Mandatory = $false)][string] $Command = 'version'
  )

  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $connect = $client.BeginConnect($HostName, $Port, $null, $null)
    if (!$connect.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(3))) {
      throw "Timed out connecting to $HostName`:$Port"
    }
    $client.EndConnect($connect)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 3000
    $stream.WriteTimeout = 3000
    $request = [System.Text.Encoding]::ASCII.GetBytes("$Command`r`nquit`r`n")
    $stream.Write($request, 0, $request.Length)
    $buffer = [byte[]]::new(512)
    $count = $stream.Read($buffer, 0, $buffer.Length)
    if ($count -le 0) {
      throw "No response from memcached at $HostName`:$Port"
    }
    return [System.Text.Encoding]::ASCII.GetString($buffer, 0, $count).Trim()
  } finally {
    $client.Close()
  }
}

function Test-MemcachedTextProtocol {
  param(
    [Parameter(Mandatory = $true)][string] $HostName,
    [Parameter(Mandatory = $true)][int] $Port
  )

  $response = Invoke-MemcachedCommand -HostName $HostName -Port $Port
  if ($response -notmatch '^VERSION\s+') {
    throw "Unexpected memcached response from $HostName`:${Port}: $response"
  }
  return $response
}

function Test-MemcachedFlush {
  param(
    [Parameter(Mandatory = $true)][string] $HostName,
    [Parameter(Mandatory = $true)][int] $Port
  )

  $response = Invoke-MemcachedCommand -HostName $HostName -Port $Port -Command 'flush_all'
  if ($response -notmatch '^OK(?:\s|$)') {
    throw "Unexpected memcached flush response from $HostName`:${Port}: $response"
  }
  return $response
}

function Update-LocalhostHostsEntry {
  if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
    return
  }

  $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  $hosts = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)
  $hosts = @($hosts | Where-Object { $_ -notmatch '^\s*(?:127\.0\.0\.1|::1)\s+localhost(?:\s|$)' })
  $hosts += '127.0.0.1 localhost'
  $hosts += '::1 localhost'
  Set-Content -LiteralPath $hostsPath -Value $hosts -Encoding ASCII
}

function Test-MemcachedCompatPort {
  param([Parameter(Mandatory = $true)][int] $Port)

  $responses = [ordered]@{}
  $responses['127.0.0.1'] = Test-MemcachedTextProtocol -HostName '127.0.0.1' -Port $Port
  $responses['127.0.0.1 flush'] = Test-MemcachedFlush -HostName '127.0.0.1' -Port $Port
  $responses['localhost'] = Test-MemcachedTextProtocol -HostName 'localhost' -Port $Port
  $responses['::1'] = Test-MemcachedTextProtocol -HostName '::1' -Port $Port
  return ,$responses
}

function Join-CommandArguments {
  param([Parameter(Mandatory = $true)][string[]] $Arguments)

  return ($Arguments | ForEach-Object {
    if ($_ -match '[\s"]') {
      '"' + ($_ -replace '"', '\"') + '"'
    } else {
      $_
    }
  }) -join ' '
}

function Get-MemcachedCompatArguments {
  param(
    [Parameter(Mandatory = $true)][int] $Port,
    [Parameter(Mandatory = $false)][AllowEmptyString()][string] $Listen = ''
  )

  $arguments = @()
  if (![string]::IsNullOrWhiteSpace($Listen)) {
    $arguments += @('-l', $Listen)
  }
  $arguments += @('-p', "$Port", '-m', '128', '-c', '4096', '-U', '0', '-B', 'auto')
  return $arguments
}

function Stop-MemcachedCompatListeners {
  param([Parameter(Mandatory = $true)][int[]] $ListenPorts)

  foreach ($port in $ListenPorts) {
    $connections = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    foreach ($connection in $connections) {
      $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
      if ($null -ne $process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Start-MemcachedCompatServer {
  param(
    [Parameter(Mandatory = $true)][string] $ReportsPath,
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'x86')][string] $Architecture
  )

  $serverRoot = Join-Path $env:RUNNER_TEMP 'zlib-rs-compat-memcached'
  Stop-MemcachedCompatListeners -ListenPorts @(11211)
  if (Test-Path -LiteralPath $serverRoot) {
    Remove-Item -LiteralPath $serverRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $serverRoot | Out-Null

  $baseUrl = 'https://github.com/jefyt/memcached-windows/releases/download/1.6.8_mingw'
  $assetArch = if ($Architecture -eq 'x86') { 'win32' } else { 'win64' }
  $memcachedZip = Join-Path $serverRoot 'memcached.zip'
  $libeventZip = Join-Path $serverRoot 'libevent.zip'
  Save-WebFile -Url "$baseUrl/memcached-1.6.8-$assetArch-mingw.zip" -Destination $memcachedZip
  Save-WebFile -Url "$baseUrl/libevent-2.1.12-stable-$assetArch-mingw.zip" -Destination $libeventZip

  $extractRoot = Join-Path $serverRoot 'server'
  Expand-Zip -Zip $memcachedZip -Destination $extractRoot
  Expand-Zip -Zip $libeventZip -Destination $extractRoot
  $memcached = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter memcached.exe -File | Select-Object -First 1
  if ($null -eq $memcached) {
    throw 'memcached.exe was not found after extracting the Windows memcached package'
  }
  Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter '*.dll' -File |
    Copy-Item -Destination $memcached.DirectoryName -Force

  Update-LocalhostHostsEntry

  $listenCandidates = @('127.0.0.1,::1', '', 'localhost')
  $errors = @()
  foreach ($listen in $listenCandidates) {
    $label = if ([string]::IsNullOrWhiteSpace($listen)) { 'all' } else { ($listen -replace '[^\w.-]+', '_') }
    $stdout = Join-Path $ReportsPath "memcached-$label.out.log"
    $stderr = Join-Path $ReportsPath "memcached-$label.err.log"
    $arguments = Get-MemcachedCompatArguments -Port 11211 -Listen $listen
    $command = "$($memcached.FullName) $(Join-CommandArguments -Arguments $arguments)"
    $process = Start-Process -FilePath $memcached.FullName -ArgumentList $arguments -WorkingDirectory $memcached.DirectoryName -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $lastError = $null
    for ($i = 0; $i -lt 20; $i++) {
      if ($process.HasExited) {
        $stdoutText = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
        $stderrText = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
        $lastError = "process exited. command=$command stdout=$stdoutText stderr=$stderrText"
        break
      }

      try {
        $responses = Test-MemcachedCompatPort -Port 11211
        $env:ZLIB_COMPAT_MEMCACHED_HOST = '127.0.0.1'
        $env:ZLIB_COMPAT_MEMCACHED_PORT = '11211'
        "memcached command: $command" | Add-Content -LiteralPath $runReport -Encoding ASCII
        foreach ($key in $responses.Keys) {
          "memcached OK on $key`:11211 ($($responses[$key]))" | Add-Content -LiteralPath $runReport -Encoding ASCII
        }
        return $process
      } catch {
        $lastError = $_
        Start-Sleep -Seconds 1
      }
    }

    $errors += "$command => $lastError"
    if (!$process.HasExited) {
      Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
  }

  Get-ChildItem -LiteralPath $ReportsPath -Filter 'memcached-*.log' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue | Out-Host }
  throw "memcached did not start on 127.0.0.1, localhost, and ::1 port 11211. Errors: $($errors -join ' | ')"
}

function Stop-MemcachedCompatServer {
  param([Parameter(Mandatory = $false)][object] $Process)

  if ($null -ne $Process -and !$Process.HasExited) {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
  }
  Stop-MemcachedCompatListeners -ListenPorts @(11211)
}

$phpArtifactsPath = Resolve-FullPath $PhpArtifactsDirectory
$extensionArtifactsPath = Resolve-FullPath $ExtensionArtifactsDirectory
$reportsPath = Resolve-FullPath $ReportsDirectory
$testPath = Resolve-FullPath 'tests/zlib-extension-compat.php'

if (!(Test-Path -LiteralPath $phpArtifactsPath -PathType Container)) {
  throw "PHP artifacts directory does not exist: $phpArtifactsPath"
}
if ($Mode -eq 'source' -and !(Test-Path -LiteralPath $extensionArtifactsPath -PathType Container)) {
  throw "Extension artifacts directory does not exist: $extensionArtifactsPath"
}
if (!(Test-Path -LiteralPath $testPath -PathType Leaf)) {
  throw "QA PHP test does not exist: $testPath"
}

New-Item -ItemType Directory -Force -Path $reportsPath | Out-Null
$runReport = Join-Path $reportsPath 'run.txt'
@(
  "mode=$Mode",
  "php_target=$PhpTarget",
  "php_run_id=$PhpRunId",
  "arch=$Arch",
  "ts=$Ts",
  "vs=$Vs",
  "allowed_missing_packages=$AllowedMissingPackages",
  "allowed_external_pecl_load_failures=$AllowedExternalPeclLoadFailures"
) | Set-Content -LiteralPath $runReport -Encoding ASCII

$phpZip = Get-PhpArtifactZip -ArtifactsDirectory $phpArtifactsPath -Arch $Arch -Ts $Ts
"php_artifact=$($phpZip.Name)" | Add-Content -LiteralPath $runReport -Encoding ASCII

$workRoot = Join-Path $env:RUNNER_TEMP "zlib-rs-extension-compat-$Mode-$PhpTarget-$Arch-$Ts"
if (Test-Path -LiteralPath $workRoot) {
  Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$phpDir = Join-Path $workRoot 'php'
Expand-Zip -Zip $phpZip.FullName -Destination $phpDir
$php = Join-Path $phpDir 'php.exe'
$extDir = Join-Path $phpDir 'ext'
if (!(Test-Path -LiteralPath $php -PathType Leaf)) {
  throw "php.exe not found after extracting $($phpZip.Name)"
}
if (!(Test-Path -LiteralPath $extDir -PathType Container)) {
  throw "Extension directory not found after extracting $($phpZip.Name)"
}

$installed = New-Object 'System.Collections.Generic.List[string]'
$skipped = New-Object 'System.Collections.Generic.List[string]'
$downloadRoot = Join-Path $workRoot 'downloads'
$packageExtractRoot = Join-Path $workRoot 'packages'
New-Item -ItemType Directory -Force -Path $downloadRoot, $packageExtractRoot | Out-Null

$packagesToInstall = New-Object 'System.Collections.Generic.List[object]'
$queuedPackages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($meta in $ExtensionMetadata) {
  foreach ($dep in $meta.Dependencies) {
    if (!$queuedPackages.Contains($dep)) {
      if (!$DependencyMetadata.ContainsKey($dep)) {
        throw "No metadata is defined for dependency $dep"
      }
      $packagesToInstall.Add($DependencyMetadata[$dep])
      $queuedPackages.Add($dep) | Out-Null
    }
  }
  if (!$queuedPackages.Contains($meta.Package)) {
    $packagesToInstall.Add($meta)
    $queuedPackages.Add($meta.Package) | Out-Null
  }
}

$phpSeries = Get-PhpSeries -PhpTarget $PhpTarget
foreach ($meta in $packagesToInstall) {
  if ($Mode -eq 'source') {
    $packageZip = Find-SourceExtensionZip -ArtifactsDirectory $extensionArtifactsPath -Package $meta.Package -Artifact $meta.Artifact -PhpTarget $PhpTarget -Ts $Ts -Vs $Vs -Arch $Arch
  } else {
    if (Test-PackageListed -Package $meta.Package) {
      $message = "Skipping allow-listed Windows PECL package $($meta.Package) php=$phpSeries arch=$Arch ts=$Ts vs=$Vs"
      $message | Add-Content -LiteralPath $runReport -Encoding ASCII
      $skipped.Add($meta.Module)
      continue
    }

    $url = Get-WindowsPeclPackageUrl -Package $meta.Package -Artifact $meta.Artifact -PhpSeries $phpSeries -Ts $Ts -Vs $Vs -Arch $Arch
    if ($null -eq $url) {
      $message = "No Windows PECL package found for $($meta.Package) php=$phpSeries arch=$Arch ts=$Ts vs=$Vs"
      $message | Add-Content -LiteralPath $runReport -Encoding ASCII
      if ($meta.Required -and !(Test-MissingPackageAllowed -Package $meta.Package)) {
        throw $message
      }
      $skipped.Add($meta.Module)
      continue
    }
    $packageZip = Join-Path $downloadRoot ([System.IO.Path]::GetFileName($url))
    Save-WebFile -Url $url -Destination $packageZip
    "pecl_package=$url" | Add-Content -LiteralPath $runReport -Encoding ASCII
  }

  Install-ExtensionPackage -PackageZip $packageZip -ExtractRoot $packageExtractRoot -PhpDirectory $phpDir -ExtensionDirectory $extDir | Out-Null
  if (!$installed.Contains($meta.Module)) {
    $installed.Add($meta.Module)
  }
}

Repair-HttpIcuDependencies -PhpDirectory $phpDir -ExtensionDirectory $extDir -Arch $Arch -Vs $Vs -RunReport $runReport

$ini = Join-Path $phpDir 'zlib-rs-extension-compat.ini'
$iniLines = [System.Collections.Generic.List[string]]::new()
$iniLines.Add('[PHP]')
$iniLines.Add("extension_dir=`"$extDir`"")
$iniLines.Add('date.timezone=UTC')
$iniLines.Add('display_errors=1')
$iniLines.Add('display_startup_errors=1')
$iniLines.Add('error_reporting=-1')
$iniLines.Add('memory_limit=512M')
$iniLines.Add('zend.assertions=1')
$iniLines.Add('xdebug.mode=develop,coverage')

if (Test-Path -LiteralPath (Join-Path $extDir 'php_zlib.dll')) {
  Add-IniLine -Lines $iniLines -Line 'extension=zlib'
}

$preloadModules = Get-UniqueOrderedStrings -Values @(
  $ExtensionMetadata |
    Where-Object { !$skipped.Contains($_.Module) } |
    ForEach-Object { $_.LoadBefore }
)
foreach ($module in $preloadModules) {
  if (Test-Path -LiteralPath (Get-PhpExtensionDllPath -ExtensionDirectory $extDir -Module $module)) {
    Add-IniLine -Lines $iniLines -Line "extension=$module"
    "preload_module=$module" | Add-Content -LiteralPath $runReport -Encoding ASCII
  }
}

foreach ($meta in $ExtensionMetadata) {
  if ($skipped.Contains($meta.Module)) {
    continue
  }
  $dll = Get-PhpExtensionDllPath -ExtensionDirectory $extDir -Module $meta.Module
  if (!(Test-Path -LiteralPath $dll)) {
    if ($meta.Required -and !($Mode -eq 'pecl' -and (Test-MissingPackageAllowed -Package $meta.Package))) {
      throw "Expected DLL for $($meta.Module) was not installed at $dll"
    }
    continue
  }
  if ($meta.Ini -eq 'zend_extension') {
    Add-IniLine -Lines $iniLines -Line "zend_extension=$($meta.Module)"
  } else {
    Add-IniLine -Lines $iniLines -Line "extension=$($meta.Module)"
  }
}

$iniLines | Set-Content -LiteralPath $ini -Encoding ASCII

$expected = @($ExtensionMetadata | ForEach-Object { $_.Module })
if ($Mode -eq 'pecl' -and $skipped.Count -gt 0) {
  $expected = @($expected | Where-Object { !$skipped.Contains($_) })
}

$memcachedProcess = $null
$oldPath = $env:PATH
$env:PATH = "$phpDir;$extDir;$env:SystemRoot\System32;$oldPath"
try {
  if ($expected -contains 'memcache' -or $expected -contains 'memcached') {
    $memcachedProcess = Start-MemcachedCompatServer -ReportsPath $reportsPath -Architecture $Arch
  }

  & $php -c $ini -v *>&1 | Tee-Object -FilePath (Join-Path $reportsPath 'php-v.txt')
  if ($LASTEXITCODE -ne 0) { throw 'php -v failed' }

  $modules = & $php -c $ini -m *>&1
  $modules | Tee-Object -FilePath (Join-Path $reportsPath 'php-m.txt')
  if ($LASTEXITCODE -ne 0) { throw 'php -m failed' }

  $moduleSet = @($modules | ForEach-Object { "$_".ToLowerInvariant() })
  $externalLoadFailures = New-Object 'System.Collections.Generic.List[string]'
  foreach ($meta in $ExtensionMetadata) {
    $module = $meta.Module
    if ($expected -notcontains $module) {
      continue
    }
    $needle = if ($module -eq 'OAuth') { 'oauth' } else { "$module".ToLowerInvariant() }
    if ($moduleSet -contains $needle) {
      continue
    }
    if (Test-ExternalPeclLoadFailureAllowed -Module $module -Package $meta.Package -Artifact $meta.Artifact) {
      $externalLoadFailures.Add($module)
      "external_pecl_load_failure=$module" | Add-Content -LiteralPath $runReport -Encoding ASCII
      continue
    }
    throw "php -m missing expected module $module"
  }

  if ($externalLoadFailures.Count -gt 0) {
    $externalSet = @($externalLoadFailures)
    $iniContent = @(Get-Content -LiteralPath $ini)
    $iniContent = @(
      $iniContent | Where-Object {
        $line = "$_"
        $excludeLine = $false
        foreach ($module in $externalSet) {
          if ($line -eq "extension=$module" -or $line -eq "zend_extension=$module") {
            $excludeLine = $true
          }
        }
        -not $excludeLine
      }
    )
    $iniContent | Set-Content -LiteralPath $ini -Encoding ASCII
    $expected = @($expected | Where-Object { $externalSet -notcontains $_ })

    $modules = & $php -c $ini -m *>&1
    $modules | Tee-Object -FilePath (Join-Path $reportsPath 'php-m.txt')
    if ($LASTEXITCODE -ne 0) { throw 'php -m failed after excluding external PECL load failures' }
    $moduleSet = @($modules | ForEach-Object { "$_".ToLowerInvariant() })
  }

  & $php -c $ini -i *>&1 | Tee-Object -FilePath (Join-Path $reportsPath 'php-i.txt')
  if ($LASTEXITCODE -ne 0) { throw 'php -i failed' }

  foreach ($module in $installed | Sort-Object -Unique) {
    if ($skipped.Contains($module) -or $externalLoadFailures.Contains($module)) {
      continue
    }
    $moduleName = if ($module -eq 'OAuth') { 'oauth' } else { $module }
    $ri = & $php -c $ini --ri $moduleName *>&1
    $ri | Tee-Object -FilePath (Join-Path $reportsPath "ri-$moduleName.txt")
    if ($LASTEXITCODE -ne 0) {
      throw "php --ri $moduleName failed"
    }
  }

  foreach ($module in $expected) {
    $needle = if ($module -eq 'OAuth') { 'oauth' } else { "$module".ToLowerInvariant() }
    if ($moduleSet -notcontains $needle) {
      throw "php -m missing expected module $module"
    }
  }

  $jsonReport = Join-Path $reportsPath 'zlib-extension-compat.json'
  $junitReport = Join-Path $reportsPath 'zlib-extension-compat.junit.xml'
  $testLog = Join-Path $reportsPath 'zlib-extension-compat.log'
  $expectedExtensions = $expected -join ','
  & $php -c $ini $testPath `
    --mode=$Mode `
    --php-target=$PhpTarget `
    --php-run-id=$PhpRunId `
    --arch=$Arch `
    --ts=$Ts `
    --vs=$Vs `
    --extensions="$expectedExtensions" `
    --json=$jsonReport `
    --junit=$junitReport *>&1 |
    Tee-Object -FilePath $testLog
  if ($LASTEXITCODE -ne 0) {
    throw 'zlib extension compatibility PHP suite failed'
  }
} finally {
  Stop-MemcachedCompatServer -Process $memcachedProcess
  $env:PATH = $oldPath
}

if ($skipped.Count -gt 0) {
  "skipped=$($skipped -join ',')" | Add-Content -LiteralPath $runReport -Encoding ASCII
}
