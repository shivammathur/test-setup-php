Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AcceptedPackages = Get-Content "$PSScriptRoot/../tests/accepted-packages.json" -Raw | ConvertFrom-Json -AsHashtable

function Save-VerifiedPackage {
    param([string]$Url, [string]$File, [string]$ReportsDirectory)
    if ($Url -notmatch '^https://downloads\.php\.net/~windows/' -or $Url.Contains('?')) {
        throw 'Only canonical, non-cache-bypassed download URLs are accepted'
    }
    $name = Split-Path $File -Leaf
    if (-not $script:AcceptedPackages.ContainsKey($name)) { throw "Unpinned package: $name" }
    New-Item $ReportsDirectory -ItemType Directory -Force | Out-Null
    $response = Invoke-WebRequest $Url -OutFile $File -PassThru
    $hash = (Get-FileHash $File -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{url=$Url; observedAt=[DateTime]::UtcNow.ToString('o'); headers=$response.Headers; sha256=$hash; acceptedSha256=$script:AcceptedPackages[$name]} |
        ConvertTo-Json -Depth 20 | Set-Content "$ReportsDirectory/$name.http.json"
    if ($hash -ne $script:AcceptedPackages[$name]) { throw "Published package differs from accepted builder bytes: $name" }
    Write-Host "Verified canonical $name SHA256=$hash"
}

function Assert-StagedSeries {
    param([string]$Php, [string]$Vs, [string]$Arch, [string]$Libxml, [string]$ReportsDirectory)
    New-Item $ReportsDirectory -ItemType Directory -Force | Out-Null
    $name = "packages-$Php-$Vs-$Arch-staging.txt"
    $url = "https://downloads.php.net/~windows/php-sdk/deps/series/$name"
    $response = Invoke-WebRequest $url
    $response.Content | Set-Content "$ReportsDirectory/$name"
    [ordered]@{url=$url; observedAt=[DateTime]::UtcNow.ToString('o'); headers=$response.Headers} |
        ConvertTo-Json -Depth 20 | Set-Content "$ReportsDirectory/$name.http.json"
    $lines = @($response.Content -split '\r?\n' | ForEach-Object { $_.Trim() })
    foreach ($expected in @("libxml2-$Libxml-$Vs-$Arch.zip", "libxslt-1.1.43-2-$Vs-$Arch.zip")) {
        $library = $expected.Split('-')[0]
        $selected = @($lines | Where-Object { $_ -match "^$library-" })
        if ($selected.Count -ne 1 -or $selected[0] -ne $expected) { throw "Stale or ambiguous series $name for $library" }
    }
    Write-Host "Verified canonical staging series $name"
}
