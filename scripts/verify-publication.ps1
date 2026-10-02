$ErrorActionPreference = 'Stop'
$manifest = Get-Content manifest.json -Raw | ConvertFrom-Json
$vs = $env:TEST_VS
$arch = $env:TEST_ARCH
$base = 'https://downloads.php.net/~windows/php-sdk/deps'
$package = "apache-2.4.69-$vs-$arch.zip"
$lane = $manifest.lanes.PSObject.Properties.Value | Where-Object vs -eq $vs | Select-Object -First 1
$artifact = $lane.build_artifacts | Where-Object name -eq ([IO.Path]::GetFileNameWithoutExtension($package))
if (@($artifact).Count -ne 1) { throw 'Expected one pinned Apache SDK artifact' }
$checks = [System.Collections.Generic.List[object]]::new()
$checks.Add([pscustomobject]@{kind='zip';url="$base/$vs/$arch/$package";expected=$artifact.digest.Substring(7)})
foreach ($php in $manifest.upload_targets.$vs.Split(',')) {
    $stabilities = if ($php -in @('8.6','8.7','master')) { @('stable','staging') } else { @('staging') }
    foreach ($stability in $stabilities) {
        $checks.Add([pscustomobject]@{kind='series';url="$base/series/packages-$php-$vs-$arch-$stability.txt";expected=$package})
    }
}
$results = [System.Collections.Generic.List[object]]::new()
foreach ($check in $checks) {
    $record = [ordered]@{url=$check.url;kind=$check.kind;expected=$check.expected;status='failed'}
    try {
        $file = Join-Path $env:RUNNER_TEMP ([Guid]::NewGuid().ToString())
        $response = Invoke-WebRequest $check.url -OutFile $file -PassThru -TimeoutSec 90
        $record.headers = $response.Headers
        $record.sha256 = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $record.observed_at = [DateTimeOffset]::UtcNow.ToString('o')
        if ($check.kind -eq 'zip') {
            if ($record.sha256 -ne $check.expected) { throw 'Published SDK hash differs from accepted builder artifact' }
        } else {
            $selection = @(Get-Content $file | Where-Object { $_ -like 'apache-*' })
            $record.apache_selection = $selection
            if ($selection.Count -ne 1 -or $selection[0] -ne $check.expected) { throw "Unexpected Apache series selection: $selection" }
        }
        $record.status = 'verified'
        Write-Host "Verified $($check.url): $($record.sha256)"
    } catch { $record.error = $_.Exception.Message; Write-Warning "$($check.url): $($record.error)" }
    $results.Add([pscustomobject]$record)
}
$results | ConvertTo-Json -Depth 12 | Set-Content publication-results.json
if (@($results | Where-Object status -ne 'verified').Count) { throw 'Some canonical downloads are not yet verified' }
