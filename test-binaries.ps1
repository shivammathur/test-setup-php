$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force results | Out-Null
Start-Transcript -Path results/smoke-tests.txt
function Invoke-Checked([string]$ExePath, [string[]]$CommandArgs) {
    & $ExePath @CommandArgs
    if ($LASTEXITCODE -ne 0) { throw "$ExePath exited with $LASTEXITCODE" }
}
function Assert-Unmarked([string]$FilePath) {
    if (Get-Item -LiteralPath $FilePath -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
        throw "Unexpected Mark-of-the-Web on $FilePath"
    }
}
$hashes = @{
    'sevenzip/bin/7za.exe' = 'e0b1d095d464c1051381a775a166e9650e74a95529dc4274a5adfd5515b406b0'
    'sevenzip/bin/7za.dll' = 'd61669cd09579fcf01f9410410840dc0dba8b735bcc5eff2bf0675961775cc05'
    'sevenzip/bin/7zxa.dll' = '291c4789ff315b941163b3dff40323b12af6b6ff0d79a153c77d649e8b0b7e87'
    'jq/bin/jq.exe' = 'a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627'
}
foreach ($entry in $hashes.GetEnumerator()) {
    $actual = (Get-FileHash $entry.Key -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $entry.Value) { throw "Hash mismatch: $($entry.Key)" }
    Write-Output "$($entry.Key): $actual"
}
foreach ($variant in @('baseline','sevenzip')) {
    $exe = (Resolve-Path "$variant/bin/7za.exe").Path
    $version = (Get-Item $exe).VersionInfo.FileVersion
    $expected = if ($variant -eq 'baseline') { '26.02' } else { '26.03' }
    if ($version -ne $expected) { throw "Unexpected version: $version" }
    Write-Output "Testing $variant 7-Zip $version"
    Invoke-Checked $exe @('i')
    $work = Join-Path $env:RUNNER_TEMP "sdk-tools-$variant"
    New-Item -ItemType Directory -Force "$work/input/nested" | Out-Null
    [IO.File]::WriteAllText("$work/input/nested/Unicode-日本語.txt", 'UTF-8: café 日本語', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes("$work/input/empty.bin", [byte[]]@())
    [IO.File]::WriteAllText("$work/input/payload.exe", 'Inert archive fixture; never executed.')
    foreach ($format in @('zip','7z')) {
        foreach ($marked in @($false,$true)) {
            if ($marked) { Set-Content -LiteralPath "$work/input/payload.exe" -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" }
            $archive = "$work/$format-$marked.$format"
            Push-Location "$work/input"
            try { Invoke-Checked $exe @('a', "-t$format", $archive, '.\*') } finally { Pop-Location }
            Assert-Unmarked $archive
            Invoke-Checked $exe @('t', $archive)
            $output = "$work/extracted-$format-$marked"
            Invoke-Checked $exe @('x', '-y', "-o$output", $archive)
            foreach ($source in Get-ChildItem "$work/input" -File -Recurse) {
                $relative = [IO.Path]::GetRelativePath("$work/input", $source.FullName)
                $target = Join-Path $output $relative
                if ((Get-FileHash $source.FullName).Hash -ne (Get-FileHash $target).Hash) { throw "Content mismatch: $relative" }
                Assert-Unmarked $target
            }
            Write-Output "PASS: $variant $format round-trip; marked input=$marked; archive and extracted files have no MOTW"
            if ($marked) { Remove-Item -LiteralPath "$work/input/payload.exe" -Stream Zone.Identifier }
        }
    }
    Set-Content -LiteralPath "$work/zip-True.zip" -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
    Invoke-Checked $exe @('x','-y','-snz',"-o$work/marked-extraction","$work/zip-True.zip")
    $zone = Get-Content -LiteralPath "$work/marked-extraction/payload.exe" -Stream Zone.Identifier -Raw
    if ($zone -notmatch 'ZoneId=3') { throw 'Explicit MOTW propagation failed' }
    Write-Output "PASS: $variant explicit extraction preserves existing MOTW"
    Invoke-Checked "$env:WINDIR/SysWOW64/WindowsPowerShell/v1.0/powershell.exe" @('-NoProfile','-File',"$PWD/test-dll.ps1",(Resolve-Path "$variant/bin").Path)
}
foreach ($variant in @('baseline','jq')) {
    $exe = (Resolve-Path "$variant/bin/jq.exe").Path
    $version = & $exe --version
    $expected = if ($variant -eq 'baseline') { 'jq-1.6' } else { 'jq-1.8.2' }
    if ($LASTEXITCODE -ne 0 -or $version -ne $expected) { throw "Unexpected jq version: $version" }
    $filter = Join-Path $env:RUNNER_TEMP 'sdk-smoke.jq'
    @'
([1,2,3] | add) == 6 and
({a:1,b:2} | .b) == 2 and
("café 日本語" | test("日本語$")) and
("café" | @uri) == "caf%C3%A9"
'@ | Set-Content $filter -Encoding utf8NoBOM
    Invoke-Checked $exe @('-n','-e','-f',$filter)
    $inputFile = Join-Path $env:RUNNER_TEMP 'sdk-smoke.json'
    '{"packages":[{"name":"libcurl","version":"8.21.0"}],"arch":"x64"}' | Set-Content $inputFile -Encoding utf8NoBOM
    $actual = & $exe -r '.packages[0].name' $inputFile
    if ($LASTEXITCODE -ne 0 -or $actual -ne 'libcurl') { throw 'jq JSON file extraction failed' }
    & $exe -n -e false
    if ($LASTEXITCODE -ne 1) { throw 'jq false exit status changed' }
    '{bad json' | Set-Content $inputFile -Encoding utf8NoBOM
    & $exe '.' $inputFile 2> results/jq-invalid-$variant.txt
    if ($LASTEXITCODE -ne 4) { throw 'jq invalid JSON exit status changed' }
    Write-Output "PASS: $version arithmetic, JSON, regex, Unicode, raw output, and exit statuses"
}
Stop-Transcript
