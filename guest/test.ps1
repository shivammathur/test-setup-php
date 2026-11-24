$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "OS=$($os.Caption) build=$($os.BuildNumber) arch=$env:PROCESSOR_ARCHITECTURE"
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Write-Host "CPU=$($cpu.Name) architecture=$($cpu.Architecture) productType=$($os.ProductType)"
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or $cpu.Architecture -ne 9 -or $os.ProductType -ne 1 -or $os.Caption -notmatch 'Windows 11') { throw 'Expected a native x64 Windows 11 client' }
Write-Host "SecureBoot=$(Confirm-SecureBootUEFI -ErrorAction Continue)"
Write-Host "TPM present=$((Get-Tpm -ErrorAction Continue).TpmPresent)"
$env:RUNNER_TEMP = Join-Path $env:TEMP ('php25711-' + [Guid]::NewGuid().ToString('N'))
New-Item $env:RUNNER_TEMP -ItemType Directory | Out-Null
$env:TEST_MODE = (Get-Content 'C:\OEM\mode.txt' -Raw).Trim()
$deadline = (Get-Date).AddMinutes(4)
while ((Get-Date) -lt $deadline) {
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        if ($mp.AntivirusEnabled) { break }
    } catch { Write-Host "Waiting for Defender to initialize" }
    Start-Sleep -Seconds 5
}
Set-MpPreference -MAPSReporting Advanced -DisableRealtimeMonitoring $false
$redis = 'C:\OEM\vc_redist.x64.exe'
$signature = Get-AuthenticodeSignature $redis
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft Corporation*') { throw 'VC++ redistributable signature verification failed' }
$rc = (Start-Process $redis -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru).ExitCode
Write-Host "VC++ runtime install exit=$rc"
if ($rc -notin 0,1638,3010) { throw 'VC++ runtime installation failed' }
$ciKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
Write-Host "Initial SAC=$((Get-MpComputerStatus).SmartAppControlState)"
if ($env:TEST_MODE -eq 'enforce' -or $env:TEST_MODE -eq 'baseline') {
  try {
    Set-ItemProperty -Path $ciKey -Name VerifiedAndReputablePolicyState -Type DWord -Value ([int]($env:TEST_MODE -eq 'enforce')) -ErrorAction Stop
    CiTool.exe --refresh -json
    Start-Sleep -Seconds 4
  } catch { Write-Host "The guest declined the test setting: $_" }
}
$reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue
Write-Host "VerifiedAndReputablePolicyState=$($reg.VerifiedAndReputablePolicyState)"
try {
  $mp = Get-MpComputerStatus
  Write-Host "SmartAppControlState=$($mp.SmartAppControlState) AntivirusEnabled=$($mp.AntivirusEnabled)"
} catch { Write-Host "Defender status unavailable: $_" }
if (Get-Command CiTool.exe -ErrorAction SilentlyContinue) {
  $policies = (CiTool.exe -lp -json | ConvertFrom-Json).Policies
  $policies | Where-Object IsEnforced | Select-Object FriendlyName,PolicyID,IsEnforced | Format-Table -AutoSize | Out-String -Width 240 | Write-Host
}
$policy = $policies | Where-Object FriendlyName -eq 'VerifiedAndReputableDesktop'
Write-Host "SAC enforcement verified by CiTool=$($policy.IsEnforced)"
if ($env:TEST_MODE -eq 'enforce' -and !$policy.IsEnforced) { throw 'Stock SAC enforcement unavailable on this image' }
if ($env:TEST_MODE -eq 'baseline' -and $policy.IsEnforced) { throw 'Baseline image already enforces SAC' }
$prefs = Get-MpPreference
Write-Host "MAPSReporting=$($prefs.MAPSReporting) DisableBlockAtFirstSeen=$($prefs.DisableBlockAtFirstSeen)"
$mpCmd = Get-ChildItem "$env:ProgramData\Microsoft\Windows Defender\Platform\*\MpCmdRun.exe" | Sort-Object FullName -Descending | Select-Object -First 1
if (!$mpCmd) { $mpCmd = Get-Item "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" }
if ($mpCmd) {
  foreach ($attempt in 1..3) {
    & $mpCmd.FullName -ValidateMapsConnection
    Write-Host "Defender cloud connectivity attempt $attempt exit=$LASTEXITCODE"
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 5
  }
  if ($LASTEXITCODE -ne 0) { throw "Defender cloud connectivity failed" }
  Write-Host "RealTimeProtectionEnabled=$((Get-MpComputerStatus).RealTimeProtectionEnabled) AMRunningMode=$((Get-MpComputerStatus).AMRunningMode)"
  Get-Service AppIDSvc,AppID,AppLockerFltr,WinDefend -ErrorAction SilentlyContinue | Select-Object Name,Status | Format-Table | Out-String | Write-Host
}
$log = 'Microsoft-Windows-CodeIntegrity/Operational'
$verboseLog = 'Microsoft-Windows-CodeIntegrity/Verbose'
wevtutil sl $verboseLog /e:true /q:true
$logInfo = Get-WinEvent -ListLog $log
Write-Host "CodeIntegrity log enabled=$($logInfo.IsEnabled)"
$base = 'https://downloads.php.net/~windows/releases'
$builds = @(
  @{ Version='8.4.27-1'; Source="$base/archives"; Sha='53db2047139bdfb8e6c7c7d5860a0a6a2a4f1dcac49fcf18ae610a14d8ccdf5b' }
  @{ Version='8.4.28'; Source=$base; Sha='59ccaa095d0f0c3fbb9f7e2bfd86713ebac032d5783cc22bc8934e2285629999' }
)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$pyDir = Join-Path $env:RUNNER_TEMP 'python-x64'
$pyZip = "$pyDir.zip"
Invoke-WebRequest 'https://www.python.org/ftp/python/3.13.16/python-3.13.16-embed-amd64.zip' -OutFile $pyZip -UseBasicParsing
if ((Get-FileHash $pyZip).Hash -ne '97dae5274cc54867065e8d5a3226e48c35017ed332a0fdb0e27d5b5821961297') { throw 'Python checksum mismatch' }
[IO.Compression.ZipFile]::ExtractToDirectory($pyZip, $pyDir)
$python = Join-Path $pyDir 'python.exe'
$pySig = Get-AuthenticodeSignature $python
Write-Host "x64 loader signature=$($pySig.Status) publisher=$($pySig.SignerCertificate.Subject)"
if ($pySig.Status -ne 'Valid') { throw 'Expected a signed loader' }
& $python -c 'import ctypes, sys; print(sys.version, sys.winver)'
if ($LASTEXITCODE) { throw 'Signed loader control failed' }
$testStart = Get-Date
foreach ($b in $builds) {
  $name = "php-$($b.Version)-Win32-vs17-x64.zip"
  $zip = Join-Path $env:RUNNER_TEMP $name
  $dir = Join-Path $env:RUNNER_TEMP "php-$($b.Version)"
  $url = "$($b.Source)/$name"
  Invoke-WebRequest $url -UseBasicParsing -OutFile $zip
  $sha = (Get-FileHash $zip -Algorithm SHA256).Hash
  if ($sha -ne $b.Sha) { throw "Checksum mismatch for $name" }
  if (!(Get-Item $zip -Stream Zone.Identifier -ErrorAction SilentlyContinue)) {
    Set-Content -LiteralPath $zip -Stream Zone.Identifier -Encoding Ascii -Value @('[ZoneTransfer]','ZoneId=3',"HostUrl=$url")
  }
  Write-Host "ZIP=$name SHA256=$sha"
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
  foreach ($file in 'php.exe','php8ts.dll') {
    $path = Join-Path $dir $file
    $sig = (Get-AuthenticodeSignature $path).Status
    $zone = [bool](Get-Item $path -Stream Zone.Identifier -ErrorAction SilentlyContinue)
    Write-Host "file=$file signature=$sig zone=$zone SHA256=$((Get-FileHash $path).Hash)"
  }
  $start = Get-Date
  try {
    $p = Start-Process (Join-Path $dir 'php.exe') -ArgumentList '-n','-v' -WorkingDirectory $dir -NoNewWindow -Wait -PassThru
    Write-Host "version=$($b.Version) exit=$($p.ExitCode)"
  } catch { Write-Host "version=$($b.Version) launch error: $_" }
  Start-Sleep -Seconds 2
  $events = @(Get-WinEvent -FilterHashtable @{LogName=@($log,$verboseLog); Id=3076,3077,3090,3091,3092; StartTime=$start} -ErrorAction SilentlyContinue | Where-Object { $_.Message -like "*php-$($b.Version)\*" })
  Write-Host "version=$($b.Version) matching Code Integrity events=$($events.Count)"
  foreach ($event in $events) { Write-Host $event.ToXml() }
  $start = Get-Date
  $dll = Join-Path $dir 'php8ts.dll'
  & $python -c 'import ctypes, sys; print(ctypes.WinDLL(sys.argv[1]))' $dll
  Write-Host "version=$($b.Version) direct DLL load exit=$LASTEXITCODE"
  Start-Sleep -Seconds 2
  $events = @(Get-WinEvent -FilterHashtable @{LogName=@($log,$verboseLog); Id=3076,3077,3090,3091,3092; StartTime=$start} -ErrorAction SilentlyContinue | Where-Object { $_.Message -like "*php-$($b.Version)\*" })
  Write-Host "version=$($b.Version) direct DLL load matching Code Integrity events=$($events.Count)"
  foreach ($event in $events) { Write-Host $event.ToXml() }
}
$detections = @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Windows Defender/Operational'; Id=1116,1117; StartTime=$testStart} -ErrorAction SilentlyContinue)
Write-Host "Antivirus detection/remediation events during test=$($detections.Count)"
foreach ($event in $detections) { Write-Host $event.ToXml() }
Write-Host 'Completed both official packages.'
exit 0
