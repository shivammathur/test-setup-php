$ErrorActionPreference = 'Stop'
$output = Join-Path $PWD 'reports/canonical-series'
New-Item -ItemType Directory -Force $output | Out-Null
$rows = @()
foreach ($expected in (Get-Content canonical-series.json -Raw | ConvertFrom-Json)) {
    $observed = [DateTimeOffset]::UtcNow.ToString('o')
    # Match Get-File's Invoke-WebRequest call, without cache-bypass headers or queries.
    $response = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $expected.url -TimeoutSec 60 -UseBasicParsing
            break
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    $bytes = $response.RawContentStream.ToArray()
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    [IO.File]::WriteAllBytes((Join-Path $output $expected.name), $bytes)
    $headers = @{}
    foreach ($header in $response.Headers.GetEnumerator()) { $headers[$header.Key] = $header.Value -join ', ' }
    $rows += [pscustomobject]@{
        name = $expected.name; url = $expected.url; observedAt = $observed
        expectedSha256 = $expected.sha256; actualSha256 = $hash
        accepted = $hash -eq $expected.sha256; headers = $headers
        dependencies = @(([Text.Encoding]::UTF8.GetString($bytes) -split '\r?\n') | Where-Object { $_ -match '^(zlib|glib|libenchant2|libpng|libzip|libcurl|libssh2|libtiff)-' })
    }
    $rows | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $output 'summary.json')
}
$stale = @($rows | Where-Object { -not $_.accepted })
Write-Host "$($rows.Count - $stale.Count)/$($rows.Count) canonical staging series match"
foreach ($row in $stale) {
    Write-Host "$($row.name): $($row.dependencies) CDN-Cache=$($row.headers['CDN-Cache']) CDN-CachedAt=$($row.headers['CDN-CachedAt']) Last-Modified=$($row.headers['Last-Modified'])"
}
if ($stale.Count) { throw 'Canonical CDN series are still stale; evidence retained' }
