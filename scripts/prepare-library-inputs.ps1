param([Parameter(Mandatory)][string]$Lane, [Parameter(Mandatory)][string]$Arch)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item reports, packages, deps -ItemType Directory -Force | Out-Null
$manifest = Get-Content expected-manifests.json -Raw | ConvertFrom-Json -AsHashtable
$config = Get-Content release-inputs.json -Raw | ConvertFrom-Json -AsHashtable
$laneConfig = $config[$Lane][$Arch]
$base = 'https://downloads.php.net/~windows'
foreach ($dependency in $laneConfig.dependencies) {
    $zip = Join-Path (Resolve-Path packages) $dependency.name
    Invoke-WebRequest "$base/$($dependency.path)/$($dependency.name)" -OutFile $zip
    Expand-Archive $zip -DestinationPath deps -Force
    "$($dependency.name) $((Get-FileHash $zip -Algorithm SHA256).Hash)" | Add-Content reports/prerequisites.txt
}
foreach ($library in @('glib', 'enchant', 'pango', 'librrd')) {
    $item = $laneConfig.libraries[$library]
    $run = gh api "repos/winlibs/winlib-builder/actions/runs/$($item.run)" | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $run.conclusion -ne 'success') { throw "Unsuccessful $library run" }
    $destination = "packages/$library"
    gh run download $item.run -R winlibs/winlib-builder -n $item.artifact -D $destination
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $library" }
    $root = (Resolve-Path $destination).Path
    $expected = $manifest[$item.artifact]
    $files = @(Get-ChildItem $root -Recurse -File)
    if ($files.Count -ne $expected.Count) { throw "File count differs: $library" }
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected[$relative] -ne $hash) { throw "File hash differs: $library/$relative" }
    }
    Copy-Item "$destination/*" deps -Recurse -Force
}
Get-ChildItem deps -Recurse -File | Get-FileHash -Algorithm SHA256 | ConvertTo-Json | Set-Content reports/input-sha256.json
"QA_LIBRARY_DEPS=$((Resolve-Path deps).Path)" >> $env:GITHUB_ENV
