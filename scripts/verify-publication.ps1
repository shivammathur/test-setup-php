$ErrorActionPreference='Stop'
$manifest=Get-Content publication-probe.json -Raw | ConvertFrom-Json -AsHashtable
$report=(New-Item reports -ItemType Directory -Force).FullName
$rows=@{}
$deadline=[DateTime]::UtcNow.AddMinutes(25)
do {
    foreach ($entry in $manifest.entries) {
        if ($rows[$entry.name] -and $rows[$entry.name].accepted) { continue }
        $row=@{name=$entry.name;kind=$entry.kind;url=$entry.url;observedAt=[DateTime]::UtcNow.ToString('o');accepted=$false}
        try {
            $path=Join-Path $env:RUNNER_TEMP $entry.name
            $response=Invoke-WebRequest $entry.url -OutFile $path -PassThru -TimeoutSec 90 -Headers @{'Accept-Encoding'='identity'}
            $row.headers=@{}
            foreach ($header in $response.Headers.GetEnumerator()) { $row.headers[$header.Key]=$header.Value -join ', ' }
            $row.sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($entry.kind -eq 'package') {
                if ($row.sha256 -ne $entry.sha256) { throw 'Published ZIP digest does not match accepted SDK artifact' }
            } else {
                $row.lines=@(Get-Content $path | Where-Object { $_.Length })
                if (($row.lines -join "`n") -cne ($entry.lines -join "`n")) { throw 'Published series does not match expected package selections' }
            }
            if ($entry.requireFreshTimestamp) {
                $modified=[DateTimeOffset]::Parse($row.headers['Last-Modified'])
                if ($modified -lt [DateTimeOffset]::Parse($manifest.notBefore)) { throw 'Published timestamp predates this upload' }
            }
            $row.accepted=$true
        } catch {
            $row.error=$_.Exception.Message
        }
        $rows[$entry.name]=$row
    }
    $accepted=@($rows.Values | Where-Object { $_.accepted }).Count
    @{runnerImage=$env:ImageOS;runnerImageVersion=$env:ImageVersion;complete=($accepted -eq $manifest.entries.Count);entries=@($rows.Values)} |
        ConvertTo-Json -Depth 8 | Set-Content (Join-Path $report 'publication.json')
    Write-Host "Verified $accepted/$($manifest.entries.Count) canonical URLs"
    if ($accepted -eq $manifest.entries.Count) { exit 0 }
    if ([DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 45 }
} while ([DateTime]::UtcNow -lt $deadline)
throw 'Canonical downloads still serve stale or missing publication data'
