param([string] $BuilderRoot = '/Users/shivammathur/php/php-windows-builder', [string] $SdkRoot = '/tmp/builder-oci-source-validation')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $BuilderRoot 'php/BuildPhp') -Force
$cases = @(
    @{ Version = '7.1.33'; Oci = '12c' },
    @{ Version = '7.2.34'; Oci = '12c' },
    @{ Version = '7.3.33'; Oci = '12c' },
    @{ Version = '7.4.33'; Oci = '12c' },
    @{ Version = '8.0.30'; Oci = '19' },
    @{ Version = '8.1.34'; Oci = '19' },
    @{ Version = '8.2.36'; Oci = '19' },
    @{ Version = '8.2.36-1'; Oci = '19' },
    @{ Version = '8.3.37'; Oci = '19' },
    @{ Version = '8.3.0RC1'; Oci = '19' },
    @{ Version = '8.3.0-dev'; Oci = '19' },
    @{ Version = '8.4.28'; Oci = '' },
    @{ Version = '8.5.12'; Oci = '' },
    @{ Version = '8.6.0RC1'; Oci = '' },
    @{ Version = '8.10.0'; Oci = '' },
    @{ Version = 'master'; Oci = '' }
)
$results = @()
foreach ($arch in @('x86', 'x64')) {
    $sdk = Join-Path $SdkRoot "$arch/instantclient/sdk"
    foreach ($case in $cases) {
        $config = Get-OciBuildConfiguration -PhpVersion $case.Version -SdkDirectory $sdk
        $expected = if ($case.Oci) { @('php_pdo_oci.dll', "php_oci8_$($case.Oci).dll") } else { @() }
        if (($config.Dlls -join ',') -ne ($expected -join ',')) { throw "Wrong DLLs for $($case.Version) $arch" }
        if ($case.Oci) {
            $resolved = (Resolve-Path $sdk).Path
            if ($config.Arguments -notcontains ('"--with-pdo-oci={0},shared"' -f $resolved)) { throw 'Missing absolute PDO OCI argument' }
            if ($config.Arguments -notcontains ('"--with-oci8-{0}={1},shared"' -f $case.Oci, $resolved)) { throw 'Missing absolute OCI8 argument' }
        } elseif ($config.Arguments.Count) { throw 'Unexpected OCI arguments' }
        $results += [PSCustomObject]@{ php = $case.Version; arch = $arch; dlls = $config.Dlls; arguments = $config.Arguments }
    }
}
$results | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $SdkRoot 'version-config-validation.json')
Write-Host "$($results.Count) PHP version / SDK combinations passed"
