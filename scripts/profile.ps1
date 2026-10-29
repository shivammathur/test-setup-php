param([Parameter(Mandatory)] [string] $Vs,[Parameter(Mandatory)] [string] $Arch)
$ErrorActionPreference='Stop'
$row=@(Get-Content native-plan.json -Raw | ConvertFrom-Json | Where-Object { $_.vs -eq $Vs -and $_.arch -eq $Arch })
if ($row.Count -ne 1) { throw 'Expected one artifact plan' }
$row=$row[0]
New-Item -ItemType Directory reports -Force | Out-Null
Invoke-WebRequest $row.baseline.url -OutFile baseline.zip
if ((Get-FileHash baseline.zip).Hash.ToLowerInvariant() -ne $row.baseline.sha256) { throw 'Baseline hash mismatch' }
if ((Get-FileHash candidate/lib/libjpeg_a.lib).Hash.ToLowerInvariant() -ne $row.candidate.library_sha256) { throw 'Candidate hash mismatch' }
Expand-Archive baseline.zip -DestinationPath baseline -Force
foreach ($variant in @('baseline','candidate')) {
    & cl /nologo /O2 /MD /W3 /D_CRT_SECURE_NO_WARNINGS "/I$variant/include" tests/jpeg-profile.c /link "/LIBPATH:$variant/lib" libjpeg_a.lib "/OUT:$variant-profile.exe"
    if ($LASTEXITCODE) { throw 'Profile executable link failed' }
}
$row | ConvertTo-Json -Depth 8 | Set-Content reports/artifacts.json -Encoding utf8
python scripts/profile.py
if ($LASTEXITCODE) { throw 'Profile failed' }
