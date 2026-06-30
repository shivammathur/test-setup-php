param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('start', 'check', 'stop')]
  [string] $Action,

  [Parameter(Mandatory = $false)]
  [int[]] $Ports = @(11211, 11212),

  [Parameter(Mandatory = $false)]
  [string] $ServerRoot = 'memcached-server',

  [Parameter(Mandatory = $false)]
  [string] $LogsDirectory = 'memcached-logs',

  [Parameter(Mandatory = $false)]
  [ValidateSet('x64', 'x86')]
  [string] $Architecture = 'x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string] $Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
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

function Update-LocalhostHostsEntry {
  $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  $hosts = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)
  $hosts = @($hosts | Where-Object { $_ -notmatch '^\s*(?:127\.0\.0\.1|::1)\s+localhost(?:\s|$)' })
  $hosts += '127.0.0.1 localhost'
  $hosts += '::1 localhost'
  Set-Content -LiteralPath $hostsPath -Value $hosts -Encoding ASCII
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
  "memcached text protocol OK on $HostName`:$Port ($response)"
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
  "memcached flush OK on $HostName`:$Port"
}

function Get-StatePath([string] $Root) {
  return Join-Path $Root 'memcached-state.json'
}

function Stop-MemcachedFromState {
  param([Parameter(Mandatory = $true)][string] $Root)

  $statePath = Get-StatePath -Root $Root
  if (!(Test-Path -LiteralPath $statePath -PathType Leaf)) {
    return
  }

  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  if ($state.PSObject.Properties.Name -contains 'tasks') {
    foreach ($task in @($state.tasks)) {
      & schtasks.exe /End /TN $task.name 2>$null | Out-Null
      & schtasks.exe /Delete /TN $task.name /F 2>$null | Out-Null
    }
  }

  if ($state.PSObject.Properties.Name -contains 'processes') {
    foreach ($process in @($state.processes)) {
      Stop-Process -Id $process.pid -Force -ErrorAction SilentlyContinue
    }
  }
}

function Stop-MemcachedListeners {
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

function Remove-MemcachedTask {
  param([Parameter(Mandatory = $true)][string] $Name)

  & schtasks.exe /End /TN $Name 2>$null | Out-Null
  & schtasks.exe /Delete /TN $Name /F 2>$null | Out-Null
}

function Get-MemcachedTaskQuery {
  param([Parameter(Mandatory = $true)][string] $Name)

  $query = & schtasks.exe /Query /TN $Name /FO LIST 2>&1
  return [PSCustomObject]@{
    exitCode = $LASTEXITCODE
    output = ($query -join "`n")
  }
}

function Get-MemcachedArguments {
  param(
    [Parameter(Mandatory = $true)][int] $Port,
    [Parameter(Mandatory = $false)][AllowEmptyString()][string] $Listen = ''
  )

  $arguments = @()
  if (![string]::IsNullOrWhiteSpace($Listen)) {
    $arguments += @('-l', $Listen)
  }

  $arguments += @(
    '-p', "$Port",
    '-m', '128',
    '-c', '4096',
    '-U', '0',
    '-B', 'auto'
  )
  return $arguments
}

function Test-MemcachedPort {
  param([Parameter(Mandatory = $true)][int] $Port)

  Test-MemcachedTextProtocol -HostName '127.0.0.1' -Port $Port | Out-Host
  Test-MemcachedFlush -HostName '127.0.0.1' -Port $Port | Out-Host
  Test-MemcachedTextProtocol -HostName 'localhost' -Port $Port | Out-Host
  Test-MemcachedTextProtocol -HostName '::1' -Port $Port | Out-Host
}

function Wait-MemcachedTaskPort {
  param(
    [Parameter(Mandatory = $true)][int] $Port,
    [Parameter(Mandatory = $true)][string] $TaskName,
    [Parameter(Mandatory = $true)][string] $Stdout,
    [Parameter(Mandatory = $true)][string] $Stderr,
    [Parameter(Mandatory = $true)][string] $Command
  )

  $lastError = $null
  for ($i = 0; $i -lt 20; $i++) {
    try {
      Test-MemcachedPort -Port $Port
      return
    } catch {
      $lastError = $_
      $query = Get-MemcachedTaskQuery -Name $TaskName
      if ($query.exitCode -ne 0) {
        $stdoutText = Get-Content -LiteralPath $Stdout -Raw -ErrorAction SilentlyContinue
        $stderrText = Get-Content -LiteralPath $Stderr -Raw -ErrorAction SilentlyContinue
        throw "memcached task $TaskName disappeared while starting port $Port. command=$Command stdout=$stdoutText stderr=$stderrText query=$($query.output)"
      }
      Start-Sleep -Seconds 1
    }
  }

  $query = Get-MemcachedTaskQuery -Name $TaskName
  $stdoutText = Get-Content -LiteralPath $Stdout -Raw -ErrorAction SilentlyContinue
  $stderrText = Get-Content -LiteralPath $Stderr -Raw -ErrorAction SilentlyContinue
  throw "memcached on port $Port did not become reachable on 127.0.0.1, localhost, and ::1. command=$Command Last error: $lastError stdout=$stdoutText stderr=$stderrText query=$($query.output)"
}

function Start-MemcachedTaskForPort {
  param(
    [Parameter(Mandatory = $true)][System.IO.FileInfo] $Memcached,
    [Parameter(Mandatory = $true)][string] $LogRoot,
    [Parameter(Mandatory = $true)][int] $Port
  )

  $listenCandidates = @('127.0.0.1,::1', '', 'localhost')
  $errors = @()
  foreach ($listen in $listenCandidates) {
    $label = if ([string]::IsNullOrWhiteSpace($listen)) { 'all' } else { ($listen -replace '[^\w.-]+', '_') }
    $stdout = Join-Path $LogRoot "memcached-$Port-$label.out.log"
    $stderr = Join-Path $LogRoot "memcached-$Port-$label.err.log"
    $arguments = Get-MemcachedArguments -Port $Port -Listen $listen
    $command = "$($Memcached.FullName) $(Join-CommandArguments -Arguments $arguments)"
    $launcher = Join-Path $LogRoot "memcached-$Port-$label.cmd"
    @(
      '@echo off',
      'setlocal',
      'set RUNNER_TRACKING_ID=',
      "cd /d `"$($Memcached.DirectoryName)`"",
      "`"$($Memcached.FullName)`" $(Join-CommandArguments -Arguments $arguments) > `"$stdout`" 2> `"$stderr`""
    ) | Set-Content -LiteralPath $launcher -Encoding ASCII

    $taskName = "\zlib-rs-memcached-$Port-$label-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $startAt = (Get-Date).AddHours(12).ToString('HH:mm')
    $taskCommand = "cmd.exe /d /c `"$launcher`""
    $create = & schtasks.exe /Create /TN $taskName /SC ONCE /ST $startAt /TR $taskCommand /F 2>&1
    if ($LASTEXITCODE -ne 0) {
      $errors += "failed to create task $taskName for ${command}: $($create -join ' ')"
      continue
    }

    $run = & schtasks.exe /Run /TN $taskName 2>&1
    if ($LASTEXITCODE -ne 0) {
      Remove-MemcachedTask -Name $taskName
      $errors += "failed to run task $taskName for ${command}: $($run -join ' ')"
      continue
    }

    try {
      Wait-MemcachedTaskPort -Port $Port -TaskName $taskName -Stdout $stdout -Stderr $stderr -Command $command
      return [PSCustomObject]@{
        name = $taskName
        port = $Port
        address = if ([string]::IsNullOrWhiteSpace($listen)) { '*' } else { $listen }
        command = $command
        launcher = $launcher
        stdout = $stdout
        stderr = $stderr
      }
    } catch {
      $errors += $_.Exception.Message
      Remove-MemcachedTask -Name $taskName
    }
  }

  throw "Could not start memcached for port $Port with any loopback bind. Errors: $($errors -join ' | ')"
}

function Start-MemcachedServers {
  param(
    [Parameter(Mandatory = $true)][string] $Root,
    [Parameter(Mandatory = $true)][string] $LogRoot,
    [Parameter(Mandatory = $true)][int[]] $ListenPorts
  )

  Stop-MemcachedFromState -Root $Root
  Stop-MemcachedListeners -ListenPorts $ListenPorts
  if (Test-Path -LiteralPath $Root) {
    Remove-Item -LiteralPath $Root -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Root, $LogRoot | Out-Null

  $baseUrl = 'https://github.com/jefyt/memcached-windows/releases/download/1.6.8_mingw'
  # GitHub's Windows runners are x64, and PHP talks to memcached over TCP.
  # The win64 daemon is the stable server package for both PHP x64 and x86 tests.
  $assetArch = 'win64'
  $memcachedZip = Join-Path $Root 'memcached.zip'
  $libeventZip = Join-Path $Root 'libevent.zip'
  Save-WebFile -Url "$baseUrl/memcached-1.6.8-$assetArch-mingw.zip" -Destination $memcachedZip
  Save-WebFile -Url "$baseUrl/libevent-2.1.12-stable-$assetArch-mingw.zip" -Destination $libeventZip

  $extractRoot = Join-Path $Root 'server'
  Expand-Zip -Zip $memcachedZip -Destination $extractRoot
  Expand-Zip -Zip $libeventZip -Destination $extractRoot
  $memcached = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter memcached.exe -File | Select-Object -First 1
  if ($null -eq $memcached) {
    throw 'memcached.exe was not found after extracting the Windows memcached package'
  }
  Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter '*.dll' -File |
    Copy-Item -Destination $memcached.DirectoryName -Force

  Update-LocalhostHostsEntry

  $tasks = @()
  foreach ($port in $ListenPorts) {
    $tasks += Start-MemcachedTaskForPort -Memcached $memcached -LogRoot $LogRoot -Port $port
  }

  [PSCustomObject]@{
    started = (Get-Date).ToString('o')
    tasks = $tasks
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-StatePath -Root $Root) -Encoding ASCII

  Test-MemcachedServers -Root $Root -ListenPorts $ListenPorts
}

function Test-MemcachedServers {
  param(
    [Parameter(Mandatory = $true)][string] $Root,
    [Parameter(Mandatory = $true)][int[]] $ListenPorts
  )

  $statePath = Get-StatePath -Root $Root
  if (!(Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "memcached state file does not exist: $statePath"
  }

  $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  if ($state.PSObject.Properties.Name -contains 'tasks') {
    foreach ($task in @($state.tasks)) {
      $query = & schtasks.exe /Query /TN $task.name /FO LIST 2>&1
      if ($LASTEXITCODE -ne 0) {
        $stdout = Get-Content -LiteralPath $task.stdout -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $task.stderr -Raw -ErrorAction SilentlyContinue
        throw "memcached task $($task.name) for port $($task.port) is not registered. stdout=$stdout stderr=$stderr query=$query"
      }
    }
  } elseif ($state.PSObject.Properties.Name -contains 'processes') {
    foreach ($process in @($state.processes)) {
      if ($null -eq (Get-Process -Id $process.pid -ErrorAction SilentlyContinue)) {
        $stdout = Get-Content -LiteralPath $process.stdout -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $process.stderr -Raw -ErrorAction SilentlyContinue
        throw "memcached process $($process.pid) for port $($process.port) is not running. stdout=$stdout stderr=$stderr"
      }
    }
  } else {
    throw "memcached state file has no tasks or processes: $statePath"
  }

  foreach ($port in $ListenPorts) {
    $ready = $false
    $lastError = $null
    for ($i = 0; $i -lt 30; $i++) {
      try {
        Test-MemcachedPort -Port $port
        $ready = $true
        break
      } catch {
        $lastError = $_
        Start-Sleep -Seconds 1
      }
    }
    if (!$ready) {
      if ($state.PSObject.Properties.Name -contains 'processes') {
        foreach ($entry in @($state.processes)) {
          if ($entry.port -eq $port) {
            Get-Content -LiteralPath $entry.stdout, $entry.stderr -ErrorAction SilentlyContinue | Out-Host
            "memcached command: $($entry.command)" | Out-Host
          }
        }
      }
      throw "memcached on port $port did not become reachable on 127.0.0.1, localhost, and ::1. Last error: $lastError"
    }
  }
}

$serverRootPath = Resolve-FullPath $ServerRoot
$logsPath = Resolve-FullPath $LogsDirectory

switch ($Action) {
  'start' {
    Start-MemcachedServers -Root $serverRootPath -LogRoot $logsPath -ListenPorts $Ports
  }
  'check' {
    Test-MemcachedServers -Root $serverRootPath -ListenPorts $Ports
  }
  'stop' {
    Stop-MemcachedFromState -Root $serverRootPath
    Stop-MemcachedListeners -ListenPorts $Ports
  }
}
