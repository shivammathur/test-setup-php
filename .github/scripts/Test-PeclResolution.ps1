param([string]$BuilderPath = 'builder')
$ErrorActionPreference = 'Stop'
$private = Join-Path $BuilderPath 'extension/BuildPhpExtension/private'
foreach ($file in @('Get-File.ps1', 'Get-OlderVsVersions.ps1', 'Get-LibrariesFromConfig.ps1', 'Get-PeclLibraryZip.ps1')) {
    . (Join-Path $private $file)
}
$manifest = Get-Content publication-manifest.json -Raw | ConvertFrom-Json
$index = Get-File 'https://downloads.php.net/~windows/pecl/deps/'
$results = @()
foreach ($php in @('8.2', '8.3', '8.4', '8.5', '8.6')) {
    $vs = if ($php -in @('8.2','8.3')) { 'vs16' } elseif ($php -in @('8.4','8.5')) { 'vs17' } else { 'vs18' }
    foreach ($arch in @('x64','x86')) {
        foreach ($probe in @(
            @{ extension='rdkafka'; library='librdkafka'; version='2.15.1'; import='librdkafka.lib' },
            @{ extension='amqp'; library='librabbitmq'; version='0.18.0'; import='rabbitmq.4.lib' }
        )) {
            $config = 'CHECK_LIB("' + $probe.import + '", "' + $probe.extension + '");'
            $libraries = @(Get-LibrariesFromConfig $php $probe.extension $vs $arch $config)
            $selected = Get-PeclLibraryZip $probe.library $php $vs $arch $index
            $expected = "$($probe.library)-$($probe.version)-$vs-$arch.zip"
            if ($selected -ne $expected) { throw "Wrong published selection: $selected; expected $expected" }
            $published = @($manifest.items | Where-Object { $_.kind -eq 'archive' -and $_.name -eq $expected })
            if ($published.Count -ne 1) { throw "Selection absent from accepted publication manifest: $expected" }
            $automatic = @($libraries | ForEach-Object { Get-PeclLibraryZip $_ $php $vs $arch $index })
            $automaticMatches = $automatic.Count -eq 1 -and $automatic[0] -eq $expected
            $results += @{ php=$php; vs=$vs; arch=$arch; extension=$probe.extension; discovered=$libraries; automaticallySelected=$automatic; automaticDiscoveryMatches=$automaticMatches; selected=$selected; sha256=$published[0].sha256 }
            if (!$automaticMatches) { Write-Warning "Existing automatic discovery selected $automatic for $php/$arch/$($probe.extension); explicit $($probe.library) selects the corrected package" }
        }
    }
}
$results | ConvertTo-Json -Depth 10 | Set-Content reports/pecl-resolution.json
Write-Host "Verified $($results.Count) published PECL selections with the restored builder resolver"
