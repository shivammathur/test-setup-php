$ErrorActionPreference = 'Stop'
$row = $env:CONSUMER_ROW | ConvertFrom-Json
New-Item packages,reports -ItemType Directory -Force | Out-Null
$proof = @()
foreach ($package in $row.packages) {
    $zip = "packages/$($package.key).zip"
    if ($package.url) {
        Invoke-WebRequest $package.url -OutFile $zip
    } else {
        Invoke-WebRequest "https://api.github.com/repos/winlibs/winlib-builder/actions/artifacts/$($package.artifact_id)/zip" -Headers @{Authorization="Bearer $env:GH_TOKEN";Accept='application/vnd.github+json'} -OutFile $zip
    }
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $package.sha256) { throw "Wrong $($package.key) archive" }
    Expand-Archive $zip "packages/$($package.key)" -Force
    $proof += @{name=$package.name;sha256=$hash;url=$package.url;run_id=$package.run_id;artifact_id=$package.artifact_id}
}
& ./builder/scripts/fetch-deps.ps1 -lib libtiff -version $row.php -vs $row.vs -arch $row.arch -stability staging -workflow_run_ids $row.override_runs -destination deps
if ((Get-FileHash deps/lib/libjpeg_a.lib -Algorithm SHA256).Hash.ToLowerInvariant() -ne $row.library_sha256) { throw 'Resolved JPEG differs from accepted SDK' }
$env:PATH = "$(Join-Path $PWD 'packages/tiff/bin');$(Join-Path $PWD 'packages/heif/bin');$env:PATH"
function Build-Check([string]$name, [string]$source, [string[]]$arguments) {
    & cl /nologo /W3 /MD "/Fe:$name.exe" $source @arguments
    if ($LASTEXITCODE) { throw "$name did not link" }
}
Build-Check tiff-shared tests/tiff-jpeg.c @('/Ipackages/tiff/include','/link','/LIBPATH:packages/tiff/lib','tiff.lib')
Build-Check tiff-static tests/tiff-jpeg.c @('/Ipackages/tiff/include','/link','/LIBPATH:packages/tiff/lib','/LIBPATH:deps/lib','tiff_a.lib','zlib_a.lib','libjpeg_a.lib','liblzma_a.lib','libzstd_a.lib','libwebp_a.lib')
Build-Check uhdr tests/uhdr-jpeg.c @('/Ipackages/ultrahdr/include','/link','/LIBPATH:packages/ultrahdr/lib','/LIBPATH:packages/jpeg/lib','uhdr_a.lib','libjpeg_a.lib')
Build-Check heif-shared builder/.github/ci/check-libheif.c @('/Ipackages/heif/include','/link','/LIBPATH:packages/heif/lib','heif.lib')
Build-Check heif-static builder/.github/ci/check-libheif.c @('/DLIBHEIF_STATIC_BUILD','/Ipackages/heif/include','/link','/LIBPATH:packages/heif/lib','/LIBPATH:packages/jpeg/lib','heif_a.lib','aom_a.lib','dav1d_a.lib','libjpeg_a.lib','Advapi32.lib')
try {
    foreach ($forced in @($false,$true)) {
        if ($forced) { $env:JSIMD_FORCENONE = '1' } else { Remove-Item Env:JSIMD_FORCENONE -ErrorAction SilentlyContinue }
        foreach ($program in @('tiff-shared','tiff-static','uhdr','heif-shared','heif-static')) {
            & "./$program.exe" 2>&1 | Tee-Object -FilePath "reports/$program-$forced.log"
            if ($LASTEXITCODE) { throw "$program failed (forced scalar: $forced)" }
        }
    }
} finally { Remove-Item Env:JSIMD_FORCENONE -ErrorAction SilentlyContinue }
@{passed=$true;phase=$row.phase;vs=$row.vs;arch=$row.arch;packages=$proof;library_sha256=$row.library_sha256} |
    ConvertTo-Json -Depth 6 | Set-Content reports/consumers.json
