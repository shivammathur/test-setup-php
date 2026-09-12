param(
    [Parameter(Mandatory)][string]$ArtifactsDirectory,
    [Parameter(Mandatory)][string]$ReportsDirectory,
    [Parameter(Mandatory)][string]$ExpectedPackages
)
$ErrorActionPreference = 'Stop'
New-Item $ReportsDirectory -ItemType Directory -Force | Out-Null
$expected = ConvertFrom-Json $ExpectedPackages -AsHashtable
$archives = @(Get-ChildItem $ArtifactsDirectory -Recurse -File | Where-Object {
    $_.Name -match '^php-(?!devel-pack-|debug-pack-|test-pack-).+?-Win32-v[sc]\d+-(?:x64|x86)\.zip$'
})
if ($archives.Count -ne 4) { throw "Expected four PHP runtime ZIPs, found $($archives.Count)." }

$extensionForLibrary = @{
    'ICU' = 'intl'
    'libcurl' = 'curl'
    'libheif' = 'gd'
    'openssl' = 'openssl'
}
function Get-ComponentProperties($Component) {
    $result = @{}
    foreach ($property in @($Component.properties)) {
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace($property.name)) {
            $result[$property.name] = $property.value
        }
    }
    return $result
}
$results = @()
foreach ($archive in $archives) {
    $root = Join-Path $env:RUNNER_TEMP ([guid]::NewGuid().ToString())
    try {
        Expand-Archive $archive.FullName $root
        $bom = Get-Content "$root/extras/sbom/php.cdx.json" -Raw | ConvertFrom-Json
        $verified = @{}
        foreach ($entry in $expected.GetEnumerator()) {
            $libraryComponents = @($bom.components | Where-Object {
                $properties = Get-ComponentProperties $_
                $_.name -eq $entry.Key -and
                    -not [string]::IsNullOrWhiteSpace($properties['php:package-file-name'])
            })
            $matches = @($libraryComponents | Where-Object {
                $properties = Get-ComponentProperties $_
                $properties['php:package-file-name'] -like "$($entry.Value)*" -and
                    $properties['php:source-commit'] -match '^[0-9a-f]{40}$'
            })
            if ($matches.Count -ne 1) {
                throw "Expected exactly one $($entry.Key) component from $($entry.Value)* with a source commit; found $($matches.Count) across $($libraryComponents.Count) package-backed components."
            }
            $verified[$entry.Key] = @($matches | ForEach-Object {
                $properties = Get-ComponentProperties $_
                @{
                    version = $_.version
                    purl = $_.purl
                    package = $properties['php:package-file-name']
                    commit = $properties['php:source-commit']
                }
            })
        }

        $loaded = @()
        foreach ($library in $expected.Keys) {
            $extension = $extensionForLibrary[$library]
            if (-not $extension -or $loaded -contains $extension) { continue }
            $arguments = @(
                '-n', '-d', "extension_dir=$root/ext", '-d', "extension=$extension", '-r',
                "if (!extension_loaded('$extension')) { fwrite(STDERR, 'missing $extension'); exit(1); } echo PHP_VERSION, ' $extension';"
            )
            $output = & "$root/php.exe" @arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Failed to load $extension for $library`: $output" }
            $loaded += $extension
        }

        $results += @{
            archive = $archive.Name
            sha256 = (Get-FileHash $archive.FullName -Algorithm SHA256).Hash
            php = $bom.metadata.component.version
            dependencies = $verified
            loadedExtensions = $loaded
        }
        Write-Host "PASS: $($archive.Name) dependency identities and runtime DLL closure"
    } finally {
        Remove-Item $root -Recurse -Force
    }
}
$results | ConvertTo-Json -Depth 10 | Set-Content "$ReportsDirectory/staged-dependencies.json"
