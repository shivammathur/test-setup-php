param([Parameter(Mandatory)] [string] $Branch)
$ErrorActionPreference='Stop'
$dumps=@(Get-ChildItem dumps -Filter '*.dmp' -ErrorAction SilentlyContinue)
if (-not $dumps.Count) { Write-Host 'No natural crash dumps were created'; return }
$cdb=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/Debuggers/x86/cdb.exe'
if (-not (Test-Path $cdb)) {
    $installer=Join-Path $env:RUNNER_TEMP 'winsdksetup.exe'
    Invoke-WebRequest 'https://go.microsoft.com/fwlink/?linkid=2382321' -OutFile $installer
    $signature=Get-AuthenticodeSignature $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Invalid SDK installer signature' }
    $p=Start-Process $installer -ArgumentList '/quiet','/norestart','/features','OptionId.WindowsDesktopDebuggers' -PassThru -Wait
    if ($p.ExitCode -notin 0,3010) { throw "Debugger installer failed: $($p.ExitCode)" }
}
$symbols=(New-Item symbols -ItemType Directory -Force).FullName
$pack=@(Get-ChildItem artifacts -Filter 'php-debug-pack-*-nts-*-x86.zip')
if ($pack.Count -ne 1) { throw 'Ambiguous exact-build debug pack' }
Expand-Archive $pack[0].FullName $symbols -Force
(Get-FileHash $pack[0].FullName -Algorithm SHA256) | ConvertTo-Json | Set-Content reports/debug-pack.json
foreach ($dump in $dumps) {
    $out=Join-Path (Resolve-Path reports).Path ($dump.BaseName+'.stack.txt')
    & $cdb -z $dump.FullName -y "$symbols;srv*$env:RUNNER_TEMP/symbol-cache*https://msdl.microsoft.com/download/symbols" -logo $out -c '.symopt+0x410;.lines -e;.reload /f;.ecxr;kv;!analyze -v;lmv m php8;lmv m php_opcache;q'
}
