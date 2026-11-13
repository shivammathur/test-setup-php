param([Parameter(Mandatory)] [string] $Branch, [string]$Arch, [string]$Ts, [string]$ArtifactDirectory='artifacts', [string]$DumpDirectory='dumps')
$ErrorActionPreference='Stop'
$dumps=@(Get-ChildItem $DumpDirectory -Filter '*.dmp' -ErrorAction SilentlyContinue)
if (-not $dumps.Count) { Write-Host 'No natural crash dumps were created'; return }
$cdb=Join-Path ${env:ProgramFiles(x86)} "Windows Kits/10/Debuggers/$Arch/cdb.exe"
if (-not (Test-Path $cdb)) {
    $installer=Join-Path $env:RUNNER_TEMP 'winsdksetup.exe'
    Invoke-WebRequest 'https://go.microsoft.com/fwlink/?linkid=2382321' -OutFile $installer
    $signature=Get-AuthenticodeSignature $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Invalid SDK installer signature' }
    $p=Start-Process $installer -ArgumentList '/quiet','/norestart','/features','OptionId.WindowsDesktopDebuggers' -PassThru -Wait
    if ($p.ExitCode -notin 0,3010) { throw "Debugger installer failed: $($p.ExitCode)" }
}
$symbols=(New-Item "symbols/$Branch" -ItemType Directory -Force).FullName
$manifest=Get-Content manifest.json -Raw | ConvertFrom-Json -AsHashtable
$pack=@(Get-ChildItem $ArtifactDirectory -Filter "php-debug-pack-*-$Arch.zip" | Where-Object { ($_.Name -match '-nts-') -eq ($Ts -eq 'nts') })
if ($pack.Count -ne 1) { throw 'Ambiguous exact-build debug pack' }
if ((Get-FileHash $pack[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.branches[$Branch].debug[$pack[0].Name]) { throw 'Debug pack hash mismatch' }
Expand-Archive $pack[0].FullName $symbols -Force
(Get-FileHash $pack[0].FullName -Algorithm SHA256) | ConvertTo-Json | Set-Content "reports/debug-pack-$Branch.json"
foreach ($dump in $dumps) {
    $out=Join-Path (Resolve-Path reports).Path ($dump.BaseName+'.stack.txt')
    & $cdb -z $dump.FullName -y "$symbols;srv*$env:RUNNER_TEMP/symbol-cache*https://msdl.microsoft.com/download/symbols" -logo $out -c '.symopt+0x410;.lines -e;.reload /f;.ecxr;kv;!analyze -v;lmv m php8*;lmv m php_opcache;q'
}
