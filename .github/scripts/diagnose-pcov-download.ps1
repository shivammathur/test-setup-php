[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('7.1', '7.2', '7.3', '7.4', '8.0', '8.1', '8.2', '8.3', '8.4', '8.5', '8.6')]
  [string] $PhpVersion,

  [Parameter(Mandatory = $true)]
  [ValidateRange(1, 100)]
  [int] $Run
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:attempts = [System.Collections.Generic.List[object]]::new()
$script:maxFailureBodyBytes = 64KB
$script:diagnosticDirectory = Join-Path $env:RUNNER_TEMP "pcov-http-$PhpVersion-$Run"
$script:reportPath = Join-Path $script:diagnosticDirectory 'report.json'
$script:curlProbeNumber = 0
$null = New-Item -Path $script:diagnosticDirectory -ItemType Directory -Force

function Convert-Headers {
  param(
    [AllowNull()]
    [object] $Headers
  )

  $result = [ordered]@{}
  if ($null -eq $Headers) {
    return [pscustomobject] $result
  }

  try {
    foreach ($header in $Headers) {
      if ($null -ne $header.Key) {
        $result[[string] $header.Key] = (@($header.Value) | ForEach-Object { [string] $_ }) -join ', '
      }
    }
  } catch {
    try {
      foreach ($key in $Headers.AllKeys) {
        $result[[string] $key] = [string] $Headers[$key]
      }
    } catch {
      $result['capture-error'] = $_.Exception.Message
    }
  }

  [pscustomobject] $result
}

function Get-BytesSnapshot {
  param(
    [AllowNull()]
    [byte[]] $Bytes,

    [int] $Limit = $script:maxFailureBodyBytes
  )

  if ($null -eq $Bytes) {
    return $null
  }

  $capturedLength = [Math]::Min($Bytes.Length, $Limit)
  $base64 = if ($capturedLength -gt 0) {
    [Convert]::ToBase64String($Bytes, 0, $capturedLength)
  } else {
    ''
  }
  $utf8 = if ($capturedLength -gt 0) {
    [Text.Encoding]::UTF8.GetString($Bytes, 0, $capturedLength)
  } else {
    ''
  }

  [pscustomobject] [ordered]@{
    totalBytes = $Bytes.Length
    capturedBytes = $capturedLength
    truncated = $Bytes.Length -gt $capturedLength
    sha256 = if ($Bytes.Length -gt 0) {
      [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    } else {
      $null
    }
    utf8 = $utf8
    base64 = $base64
  }
}

function Get-ExceptionChain {
  param(
    [Parameter(Mandatory = $true)]
    [Exception] $Exception
  )

  $chain = [System.Collections.Generic.List[object]]::new()
  $current = $Exception
  $depth = 0
  while ($null -ne $current -and $depth -lt 10) {
    $properties = [ordered]@{
      depth = $depth
      type = $current.GetType().FullName
      message = $current.Message
      hResult = ('0x{0:x8}' -f $current.HResult)
      source = $current.Source
    }
    foreach ($name in @('Status', 'StatusCode', 'ErrorCode', 'NativeErrorCode', 'SocketErrorCode')) {
      $property = $current.PSObject.Properties[$name]
      if ($null -ne $property -and $null -ne $property.Value) {
        $properties[$name] = [string] $property.Value
      }
    }
    [void] $chain.Add([pscustomobject] $properties)
    $current = $current.InnerException
    $depth++
  }

  @($chain)
}

function Get-ErrorResponse {
  param(
    [Parameter(Mandatory = $true)]
    [Exception] $Exception
  )

  $current = $Exception
  while ($null -ne $current) {
    $responseProperty = $current.PSObject.Properties['Response']
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
      return $responseProperty.Value
    }
    $current = $current.InnerException
  }

  $null
}

function Get-ResponseSnapshot {
  param(
    [AllowNull()]
    [object] $Response,

    [switch] $IncludeBody
  )

  if ($null -eq $Response) {
    return $null
  }

  $message = $Response
  $baseResponseProperty = $Response.PSObject.Properties['BaseResponse']
  if ($null -ne $baseResponseProperty -and $null -ne $baseResponseProperty.Value) {
    $message = $baseResponseProperty.Value
  }

  $statusCode = $null
  $statusCodeProperty = $message.PSObject.Properties['StatusCode']
  if ($null -ne $statusCodeProperty -and $null -ne $statusCodeProperty.Value) {
    try {
      $statusCode = [int] $statusCodeProperty.Value
    } catch {
      $statusCode = [string] $statusCodeProperty.Value
    }
  }

  $reasonPhrase = $null
  foreach ($name in @('ReasonPhrase', 'StatusDescription')) {
    $property = $message.PSObject.Properties[$name]
    if ($null -ne $property -and $null -ne $property.Value) {
      $reasonPhrase = [string] $property.Value
      break
    }
  }

  $responseHeaders = [ordered]@{}
  $headersProperty = $message.PSObject.Properties['Headers']
  if ($null -ne $headersProperty) {
    $responseHeaders['response'] = Convert-Headers $headersProperty.Value
  }

  $contentProperty = $message.PSObject.Properties['Content']
  if ($null -ne $contentProperty -and $null -ne $contentProperty.Value) {
    $contentHeadersProperty = $contentProperty.Value.PSObject.Properties['Headers']
    if ($null -ne $contentHeadersProperty) {
      $responseHeaders['content'] = Convert-Headers $contentHeadersProperty.Value
    }
  }

  $request = $null
  $requestMessageProperty = $message.PSObject.Properties['RequestMessage']
  if ($null -ne $requestMessageProperty -and $null -ne $requestMessageProperty.Value) {
    $requestMessage = $requestMessageProperty.Value
    $requestContentHeaders = $null
    if ($null -ne $requestMessage.Content) {
      $requestContentHeaders = Convert-Headers $requestMessage.Content.Headers
    }
    $request = [pscustomobject] [ordered]@{
      method = [string] $requestMessage.Method
      uri = [string] $requestMessage.RequestUri
      version = [string] $requestMessage.Version
      versionPolicy = [string] $requestMessage.VersionPolicy
      headers = Convert-Headers $requestMessage.Headers
      contentHeaders = $requestContentHeaders
    }
  }

  $body = $null
  $bodyCaptureError = $null
  if ($IncludeBody) {
    try {
      $bytes = $null
      if ($null -ne $contentProperty -and $null -ne $contentProperty.Value) {
        $readMethod = $contentProperty.Value.PSObject.Methods['ReadAsByteArrayAsync']
        if ($null -ne $readMethod) {
          $bytes = $contentProperty.Value.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        } elseif ($contentProperty.Value -is [string]) {
          $bytes = [Text.Encoding]::UTF8.GetBytes([string] $contentProperty.Value)
        }
      }
      if ($null -eq $bytes) {
        $streamMethod = $message.PSObject.Methods['GetResponseStream']
        if ($null -ne $streamMethod) {
          $stream = $message.GetResponseStream()
          try {
            $memory = [IO.MemoryStream]::new()
            try {
              $stream.CopyTo($memory)
              $bytes = $memory.ToArray()
            } finally {
              $memory.Dispose()
            }
          } finally {
            $stream.Dispose()
          }
        }
      }
      $body = Get-BytesSnapshot -Bytes $bytes
    } catch {
      $bodyCaptureError = $_.Exception.Message
    }
  }

  [pscustomobject] [ordered]@{
    type = $message.GetType().FullName
    statusCode = $statusCode
    reasonPhrase = $reasonPhrase
    version = if ($null -ne $message.PSObject.Properties['Version']) { [string] $message.Version } else { $null }
    headers = [pscustomobject] $responseHeaders
    request = $request
    body = $body
    bodyCaptureError = $bodyCaptureError
  }
}

function Invoke-CurlProbe {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Uri
  )

  $script:curlProbeNumber++
  $prefix = 'curl-{0:d2}' -f $script:curlProbeNumber
  $headersPath = Join-Path $script:diagnosticDirectory "$prefix-headers.txt"
  $bodyPath = Join-Path $script:diagnosticDirectory "$prefix-body.bin"
  $tracePath = Join-Path $script:diagnosticDirectory "$prefix-trace.txt"

  $metrics = & curl.exe `
    --location `
    --silent `
    --show-error `
    --verbose `
    --connect-timeout 20 `
    --max-time 60 `
    --dump-header $headersPath `
    --output $bodyPath `
    --write-out 'http_code=%{http_code};http_version=%{http_version};remote_ip=%{remote_ip};remote_port=%{remote_port};time_namelookup=%{time_namelookup};time_connect=%{time_connect};time_appconnect=%{time_appconnect};time_starttransfer=%{time_starttransfer};time_total=%{time_total};size_download=%{size_download};speed_download=%{speed_download}' `
    $Uri 2> $tracePath
  $exitCode = $LASTEXITCODE

  $headers = if (Test-Path -LiteralPath $headersPath) {
    Get-Content -LiteralPath $headersPath -Raw
  } else {
    $null
  }
  $trace = if (Test-Path -LiteralPath $tracePath) {
    Get-Content -LiteralPath $tracePath -Raw
  } else {
    $null
  }
  $body = $null
  if (Test-Path -LiteralPath $bodyPath) {
    $bytes = [IO.File]::ReadAllBytes($bodyPath)
    $captureLimit = if ([string] $metrics -match 'http_code=2\d\d') { 64 } else { $script:maxFailureBodyBytes }
    $body = Get-BytesSnapshot -Bytes $bytes -Limit $captureLimit
  }

  [pscustomobject] [ordered]@{
    command = 'curl.exe --location --silent --show-error --verbose --connect-timeout 20 --max-time 60 --dump-header <file> --output <file> <uri>'
    exitCode = $exitCode
    metrics = [string] $metrics
    responseHeaders = $headers
    verboseTrace = $trace
    body = $body
    rawFiles = [pscustomobject] [ordered]@{
      headers = [IO.Path]::GetFileName($headersPath)
      trace = [IO.Path]::GetFileName($tracePath)
      body = [IO.Path]::GetFileName($bodyPath)
    }
  }
}

function Invoke-CapturedRequest {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Uri,

    [Parameter(Mandatory = $true)]
    [string] $Phase,

    [string] $OutFile = '',

    [int] $Retries = 3
  )

  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    if ($OutFile -ne '' -and (Test-Path -LiteralPath $OutFile)) {
      Remove-Item -LiteralPath $OutFile -Force
    }

    $startedAt = [DateTimeOffset]::UtcNow
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
      $parameters = @{
        Uri = $Uri
        UseBasicParsing = $true
        Verbose = $false
      }
      if ($OutFile -ne '') {
        $parameters['OutFile'] = $OutFile
      }
      $response = Invoke-WebRequest @parameters
      $stopwatch.Stop()
      $record = [pscustomobject] [ordered]@{
        phase = $Phase
        uri = $Uri
        attempt = $attempt
        startedAt = $startedAt.ToString('o')
        durationMilliseconds = $stopwatch.ElapsedMilliseconds
        success = $true
        invokeWebRequest = [pscustomobject] [ordered]@{
          useBasicParsing = $true
          outFile = $OutFile -ne ''
          powershellVersion = $PSVersionTable.PSVersion.ToString()
        }
        response = Get-ResponseSnapshot -Response $response
        error = $null
        curlProbe = $null
      }
      [void] $script:attempts.Add($record)
      Write-Host "Invoke-WebRequest succeeded: phase=$Phase attempt=$attempt duration=$($stopwatch.ElapsedMilliseconds)ms uri=$Uri"
      return $response
    } catch {
      $stopwatch.Stop()
      $errorRecord = $_
      $errorResponse = Get-ErrorResponse -Exception $errorRecord.Exception
      $curlProbe = if ($attempt -eq $Retries) {
        Invoke-CurlProbe -Uri $Uri
      } else {
        $null
      }
      $record = [pscustomobject] [ordered]@{
        phase = $Phase
        uri = $Uri
        attempt = $attempt
        startedAt = $startedAt.ToString('o')
        durationMilliseconds = $stopwatch.ElapsedMilliseconds
        success = $false
        invokeWebRequest = [pscustomobject] [ordered]@{
          useBasicParsing = $true
          outFile = $OutFile -ne ''
          powershellVersion = $PSVersionTable.PSVersion.ToString()
        }
        response = Get-ResponseSnapshot -Response $errorResponse -IncludeBody
        error = [pscustomobject] [ordered]@{
          fullyQualifiedErrorId = $errorRecord.FullyQualifiedErrorId
          category = [string] $errorRecord.CategoryInfo
          errorDetails = if ($null -ne $errorRecord.ErrorDetails) { $errorRecord.ErrorDetails.Message } else { $null }
          rendered = ($errorRecord | Out-String)
          exceptionChain = Get-ExceptionChain -Exception $errorRecord.Exception
        }
        curlProbe = $curlProbe
      }
      [void] $script:attempts.Add($record)

      Write-Host "::group::Captured failure: phase=$Phase attempt=$attempt"
      Write-Host ($record | ConvertTo-Json -Depth 20 -Compress)
      Write-Host '::endgroup::'

      if ($attempt -eq $Retries) {
        throw
      }
    }
  }
}

function Get-Toolset {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Version
  )

  switch -Regex ($Version) {
    '^7\.1$' { '14'; break }
    '^7\.[2-4]$' { '15'; break }
    '^8\.[0-3]$' { '16'; break }
    '^8\.[4-6]$' { '17'; break }
    default { throw "Unsupported PHP version: $Version" }
  }
}

$outcome = 'success'
$selectedUri = $null
$download = $null
$terminalError = $null

try {
  $downloadPath = Join-Path $script:diagnosticDirectory 'pcov-download.bin'
  if ($PhpVersion -eq '8.6') {
    $selectedUri = 'https://github.com/shivammathur/php-extensions-windows/releases/download/builds/php8.6_nts_x64_pcov.dll'
    $download = Invoke-CapturedRequest -Uri $selectedUri -Phase 'github-archive' -OutFile $downloadPath
  } else {
    $toolset = Get-Toolset -Version $PhpVersion
    $releases = @('1.0.12', '1.0.11', '1.0.10', '1.0.9', '1.0.8', '1.0.7', '1.0.6', '1.0.5', '1.0.4', '1.0.3', '1.0.2', '1.0.1', '1.0.0')
    foreach ($release in $releases) {
      $indexUri = "https://downloads.php.net/~windows/pecl/releases/pcov/$release/"
      $index = Invoke-CapturedRequest -Uri $indexUri -Phase "pecl-index-$release"
      $escapedRelease = [regex]::Escape($release)
      $escapedPhp = [regex]::Escape($PhpVersion)
      $filePattern = "^php_pcov-$escapedRelease-$escapedPhp-nts-(?:VC|vc|vs)$toolset-x64\.zip$"
      $link = @($index.Links | Where-Object { $_.Href -match $filePattern } | Select-Object -First 1)
      if ($link.Count -eq 1) {
        $selectedUri = [Uri]::new([Uri] $indexUri, [string] $link[0].Href).AbsoluteUri
        break
      }
    }

    if ($null -eq $selectedUri) {
      throw "No compatible PCOV archive found for PHP $PhpVersion"
    }
    $download = Invoke-CapturedRequest -Uri $selectedUri -Phase 'pecl-archive' -OutFile $downloadPath
  }

  if (-not(Test-Path -LiteralPath $downloadPath -PathType Leaf)) {
    throw "The request succeeded but did not create $downloadPath"
  }
  $download = [pscustomobject] [ordered]@{
    path = [IO.Path]::GetFileName($downloadPath)
    bytes = (Get-Item -LiteralPath $downloadPath).Length
    sha256 = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    firstBytes = [Convert]::ToHexString(([IO.File]::ReadAllBytes($downloadPath) | Select-Object -First 8)).ToLowerInvariant()
  }
} catch {
  $outcome = 'failure'
  $terminalError = [pscustomobject] [ordered]@{
    fullyQualifiedErrorId = $_.FullyQualifiedErrorId
    category = [string] $_.CategoryInfo
    rendered = ($_ | Out-String)
    exceptionChain = Get-ExceptionChain -Exception $_.Exception
  }
}

$report = [pscustomobject] [ordered]@{
  schemaVersion = 1
  collectedAt = [DateTimeOffset]::UtcNow.ToString('o')
  outcome = $outcome
  phpVersion = $PhpVersion
  run = $Run
  selectedUri = $selectedUri
  runner = [pscustomobject] [ordered]@{
    name = $env:RUNNER_NAME
    os = $env:RUNNER_OS
    architecture = $env:RUNNER_ARCH
    imageOS = $env:ImageOS
    imageVersion = $env:ImageVersion
    powershell = $PSVersionTable | Select-Object PSVersion, PSEdition, GitCommitId, OS, Platform
  }
  attempts = @($script:attempts)
  download = $download
  terminalError = $terminalError
}

[IO.File]::WriteAllText(
  $script:reportPath,
  ($report | ConvertTo-Json -Depth 20),
  [Text.UTF8Encoding]::new($false)
)

@"
### PCOV HTTP diagnostic

- PHP: $PhpVersion
- Matrix attempt: $Run
- Outcome: $outcome
- Selected URL: $selectedUri
- Captured requests: $($script:attempts.Count)
- Report: $script:reportPath
"@ | Out-File -LiteralPath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8

Write-Host "Diagnostic report: $script:reportPath"
if ($outcome -eq 'failure') {
  Write-Host '::group::Terminal diagnostic report'
  Write-Host ($report | ConvertTo-Json -Depth 20 -Compress)
  Write-Host '::endgroup::'
  throw "PCOV download diagnostic failed for PHP $PhpVersion; inspect the uploaded HTTP diagnostic artifact"
}
