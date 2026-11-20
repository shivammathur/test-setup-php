$ErrorActionPreference = 'Stop'
Import-Module ./builder/php/BuildPhp -Force
$sourceRoot = Join-Path $PWD 'source-fixtures'
$results = @()
foreach ($arch in @('x86', 'x64')) {
    $sdkRoot = Join-Path $env:RUNNER_TEMP "oci-sdk-$arch"
    $null = New-Item -ItemType Directory -Path $sdkRoot -Force
    Push-Location $sdkRoot
    try {
        Get-OciSdk -Arch $arch
        foreach ($version in @('7.2.34','7.3.33','7.4.33','8.0.30','8.1.34','8.2.36','8.3.37','8.4.28')) {
            $source = Join-Path $sourceRoot $version
            $sdk = Join-Path $sdkRoot 'instantclient/sdk'
            $config = Get-OciBuildConfiguration -SourceDirectory $source -SdkDirectory $sdk
            $expected = if ($version -like '7.*') { @('php_pdo_oci.dll', 'php_oci8_12c.dll') } elseif ($version -like '8.4.*') { @() } else { @('php_pdo_oci.dll', 'php_oci8_19.dll') }
            if (($config.Dlls -join ',') -ne ($expected -join ',')) { throw "Unexpected OCI DLLs for $version $arch" }
            $results += [PSCustomObject]@{ php = $version; arch = $arch; dlls = $config.Dlls; arguments = $config.Arguments }
            Write-Host "$version $arch -> $($config.Dlls -join ', ')"
        }
    } finally { Pop-Location }
}
$results | ConvertTo-Json -Depth 6 | Set-Content sdk-validation.json
