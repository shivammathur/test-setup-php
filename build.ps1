$ErrorActionPreference = 'Stop'
$root = $PWD.Path
Push-Location source
try {
    $sha = (git rev-parse HEAD).Trim()
    if ($sha -ne $env:SOURCE_SHA) { throw "Wrong source: $sha" }
    & cmd.exe /d /c .github\scripts\windows\build.bat 2>&1 | Tee-Object "$root/build.log"
    if ($LASTEXITCODE) { throw "PHP build failed: $LASTEXITCODE" }
    if (git status --porcelain --untracked-files=no) { throw 'Tracked source changed during build' }
} finally {
    Pop-Location
}
$release = if ($env:PHPTS -eq 'ts') { 'Release_TS' } else { 'Release' }
$dll = if ($env:PHPTS -eq 'ts') { 'php8ts.dll' } else { 'php8.dll' }
New-Item -ItemType Directory runtime | Out-Null
Copy-Item "C:/obj/$release/php.exe", "C:/obj/$release/$dll" runtime/
Copy-Item C:/build-cache/deps-8.4-vs17-x64/bin/*.dll runtime/
$identity = & ./runtime/php.exe -n -r 'echo json_encode(["version" => PHP_VERSION, "zts" => PHP_ZTS, "bits" => PHP_INT_SIZE * 8]);'
if ($LASTEXITCODE) { throw 'Built PHP does not start' }
$identity = $identity | ConvertFrom-Json
if ($identity.zts -ne [int]$env:THREAD_SAFE -or $identity.bits -ne 64) { throw 'Wrong runtime identity' }
$hashes = @(Get-ChildItem runtime -File | ForEach-Object {
    @{ name = $_.Name; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
})
@{ variant = $env:VARIANT; sha = $sha; ts = $env:PHPTS; runtime = $identity; files = $hashes } |
    ConvertTo-Json -Depth 5 | Set-Content runtime/provenance.json
