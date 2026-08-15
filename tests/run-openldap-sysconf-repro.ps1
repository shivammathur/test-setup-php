[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $ExpectedCertificateVerifyFailure,

  [string] $Php = 'php',

  [string] $ExtensionDir = '',

  [int] $Port = 4636
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Bool([string] $Value) {
  switch ($Value.ToLowerInvariant()) {
    'true' { return $true }
    'false' { return $false }
    default { throw "Invalid boolean value: $Value" }
  }
}

function Write-PemCertificate([string] $DerPath, [string] $PemPath) {
  $bytes = [IO.File]::ReadAllBytes($DerPath)
  $base64 = [Convert]::ToBase64String(
    $bytes,
    [Base64FormattingOptions]::InsertLineBreaks
  )
  [IO.File]::WriteAllText(
    $PemPath,
    "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----`n",
    [Text.Encoding]::ASCII
  )
}

function Find-OpenLdapPathNeedles([string[]] $Paths) {
  $needles = @(
    'C:\openldap\sysconf\ldap.conf',
    'C?3?2openldap?2sysconf?2ldap?4conf'
  )

  foreach ($path in $Paths) {
    if (-not (Test-Path $path)) {
      continue
    }

    $item = Get-Item $path
    if ($item.Length -ge 100MB) {
      continue
    }

    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($item.FullName))
    foreach ($needle in $needles) {
      if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        [PSCustomObject]@{
          File = $item.FullName
          Needle = $needle
        }
      }
    }
  }
}

$expected = ConvertTo-Bool $ExpectedCertificateVerifyFailure

Remove-Item Env:\LDAPCONF -ErrorAction SilentlyContinue
Remove-Item Env:\LDAPRC -ErrorAction SilentlyContinue

$openldapRoot = 'C:\openldap'
$certDir = Join-Path $openldapRoot 'certs'
$sysconfDir = Join-Path $openldapRoot 'sysconf'
$caDerPath = Join-Path $certDir 'php22207-ca.cer'
$caPemPath = Join-Path $certDir 'php22207-ca.pem'
$pfxPath = Join-Path $certDir 'php22207-server.pfx'
$pfxPasswordPlain = 'php22207'
$ca = $null
$server = $null
$serverJob = $null

try {
  Remove-Item $openldapRoot -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $certDir, $sysconfDir -Force | Out-Null

  $ca = New-SelfSignedCertificate `
    -Type Custom `
    -Subject 'CN=PHP22207 Test CA' `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -KeyExportPolicy Exportable `
    -KeyUsage CertSign, CRLSign, DigitalSignature `
    -KeyUsageProperty All `
    -HashAlgorithm SHA256 `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddDays(2)

  $server = New-SelfSignedCertificate `
    -Type Custom `
    -Subject 'CN=127.0.0.1' `
    -Signer $ca `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -KeyExportPolicy Exportable `
    -KeyUsage DigitalSignature, KeyEncipherment `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
    -HashAlgorithm SHA256 `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -NotAfter (Get-Date).AddDays(2)

  Export-Certificate -Cert $ca -FilePath $caDerPath -Force | Out-Null
  Write-PemCertificate -DerPath $caDerPath -PemPath $caPemPath

  $pfxPassword = ConvertTo-SecureString $pfxPasswordPlain -AsPlainText -Force
  Export-PfxCertificate -Cert $server -FilePath $pfxPath -Password $pfxPassword -Force | Out-Null

$ldapConf = @"
TLS_CACERT $caPemPath
TLS_REQCERT demand
"@
  Set-Content -Path (Join-Path $sysconfDir 'ldap.conf') -Value $ldapConf -Encoding ASCII

  Write-Host 'ldap.conf:'
  Get-Content (Join-Path $sysconfDir 'ldap.conf') | ForEach-Object { Write-Host $_ }

  if (Test-Path $Php) {
    $php = (Resolve-Path $Php).Path
  } else {
    $php = (Get-Command $Php).Source
  }
  $phpRoot = Split-Path $php -Parent
  if (-not $ExtensionDir) {
    $ExtensionDir = Join-Path $phpRoot 'ext'
  }
  $env:PATH = "$phpRoot;$env:PATH"
  Write-Host "php.exe: $php"
  Write-Host "php root: $phpRoot"
  Write-Host "extension dir: $ExtensionDir"

  $pathMatches = @(Find-OpenLdapPathNeedles -Paths @(
    $php,
    (Join-Path $phpRoot 'php8ts.dll'),
    (Join-Path $phpRoot 'php8.dll'),
    (Join-Path $phpRoot 'libldap.dll'),
    (Join-Path $ExtensionDir 'php_ldap.dll')
  ))
  if ($pathMatches.Count -eq 0) {
    Write-Host 'No C:\openldap\sysconf\ldap.conf marker found in PHP files.'
  } else {
    Write-Host 'OpenLDAP sysconf markers found in PHP files:'
    $pathMatches | ForEach-Object {
      Write-Host "$($_.File) :: $($_.Needle)"
    }
  }

  $serverJob = Start-Job -Name php22207-ldaps-probe -ArgumentList $Port, $pfxPath, $pfxPasswordPlain -ScriptBlock {
    param($Port, $PfxPath, $Password)

    $ErrorActionPreference = 'Stop'

    function Get-LdapMessageId([byte[]] $Buffer, [int] $Length) {
      for ($i = 0; $i -lt ($Length - 3); $i++) {
        if ($Buffer[$i] -eq 0x02 -and $Buffer[$i + 1] -eq 0x01) {
          return $Buffer[$i + 2]
        }
      }

      return 1
    }

    function New-LdapBindSuccessResponse([int] $MessageId) {
      return [byte[]] @(
        0x30, 0x0c,
        0x02, 0x01, ($MessageId -band 0xff),
        0x61, 0x07,
        0x0a, 0x01, 0x00,
        0x04, 0x00,
        0x04, 0x00
      )
    }

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PfxPath, $Password)
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::IPv6Any, $Port)
    try {
      $listener.Server.DualMode = $true
    } catch {
      Write-Output "Unable to enable dual-stack listener mode: $($_.Exception.Message)"
    }
    $listener.Start()

    try {
      for ($i = 0; $i -lt 1; $i++) {
        $client = $listener.AcceptTcpClient()
        try {
          $stream = $client.GetStream()
          $ssl = New-Object System.Net.Security.SslStream($stream, $false)
          try {
            $stream.ReadTimeout = 5000
            $stream.WriteTimeout = 5000
            $ssl.AuthenticateAsServer(
              $cert,
              $false,
              [System.Security.Authentication.SslProtocols]::Tls12,
              $false
            )

            $client.ReceiveTimeout = 1000
            $buffer = New-Object byte[] 4096
            try {
              $bytesRead = $ssl.Read($buffer, 0, $buffer.Length)
              if ($bytesRead -gt 0) {
                $messageId = Get-LdapMessageId -Buffer $buffer -Length $bytesRead
                $response = New-LdapBindSuccessResponse -MessageId $messageId
                $ssl.Write($response, 0, $response.Length)
                $ssl.Flush()
                Write-Output "TLS server sent LDAP bind success for message id $messageId"
              }
            } catch {
              Write-Output "TLS server read ended: $($_.Exception.Message)"
            }
          } catch {
            Write-Output "TLS server handshake ended: $($_.Exception.Message)"
          } finally {
            if ($ssl) {
              $ssl.Dispose()
            }
          }
        } finally {
          $client.Close()
        }
      }
    } finally {
      $listener.Stop()
    }
  }

  Start-Sleep -Seconds 1

  $stdout = Join-Path $env:TEMP 'php22207-stdout.txt'
  $stderr = Join-Path $env:TEMP 'php22207-stderr.txt'
  Remove-Item $stdout, $stderr -Force -ErrorAction SilentlyContinue

  $phpArgs = @(
    '-n',
    '-d',
    "extension_dir=$ExtensionDir",
    '-d',
    'extension=openssl',
    '-d',
    'extension=ldap',
    '.\tests\ldap-conf-repro.php',
    '127.0.0.1',
    "$Port"
  )

  Write-Host 'Starting PHP repro child process...'
  $process = Start-Process `
    -FilePath $php `
    -ArgumentList $phpArgs `
    -NoNewWindow `
    -PassThru `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr

  $timedOut = -not $process.WaitForExit(20000)
  if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
  }

  $phpExitCode = $process.ExitCode
  $phpOutput = @()
  if (Test-Path $stdout) {
    $phpOutput += Get-Content $stdout
  }
  if (Test-Path $stderr) {
    $phpOutput += Get-Content $stderr
  }

  Write-Host 'PHP repro output:'
  $phpOutput | ForEach-Object { Write-Host $_ }
  Write-Host "PHP repro exit code: $phpExitCode"
  Write-Host "PHP repro timed out: $timedOut"

  $jsonLine = $phpOutput |
    Where-Object { $_.StartsWith('JSON_RESULT=') } |
    Select-Object -Last 1

  if (-not $jsonLine) {
    throw 'PHP repro did not emit JSON_RESULT.'
  }

  $json = $jsonLine.Substring('JSON_RESULT='.Length)
  $result = $json | ConvertFrom-Json
  $actual = [bool] $result.certificate_verify_failed

  Write-Host "Expected certificate_verify_failed=$expected"
  Write-Host "Actual certificate_verify_failed=$actual"

  if ($actual -ne $expected) {
    throw "Unexpected certificate verification result for PHP at $php"
  }

  if ($expected) {
    if ([bool] $result.bind) {
      throw 'Expected the regression case to fail before LDAP bind success.'
    }
    Write-Host 'Regression reproduced: ldap.conf CA was not used for LDAPS.'
  } else {
    if (-not [bool] $result.bind) {
      throw 'Expected the fixed build to complete LDAP bind successfully.'
    }
    Write-Host 'Fix verified: ldap.conf CA was used and LDAP bind succeeded.'
  }
} finally {
  if ($serverJob) {
    Stop-Job $serverJob -ErrorAction SilentlyContinue
    Receive-Job $serverJob -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    Remove-Job $serverJob -Force -ErrorAction SilentlyContinue
  }
  if ($server) {
    Remove-Item "Cert:\CurrentUser\My\$($server.Thumbprint)" -Force -ErrorAction SilentlyContinue
  }
  if ($ca) {
    Remove-Item "Cert:\CurrentUser\My\$($ca.Thumbprint)" -Force -ErrorAction SilentlyContinue
  }
}
