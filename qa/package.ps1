param(
    [Parameter(Mandatory)][ValidateSet('x64', 'x86')][string]$Arch,
    [Parameter(Mandatory)][ValidateSet('vs16', 'vs17', 'vs18')][string]$Vs,
    [Parameter(Mandatory)][string]$Version
)
$ErrorActionPreference = 'Stop'
New-Item validation -ItemType Directory -Force | Out-Null
$licenses = @(
    'OpenBLAS/LICENSE.OpenBLAS', 'OpenBLAS/LICENSE.OpenBLAS-LAPACK',
    'gcc-libs/LICENSE.OpenBLAS-GCC-COPYING3', 'gcc-libs/LICENSE.OpenBLAS-GCC-COPYING.LIB',
    'gcc-libs/LICENSE.OpenBLAS-GCC-COPYING.RUNTIME', 'gcc-libs/LICENSE.OpenBLAS-libbacktrace',
    'mingw-w64/LICENSE.OpenBLAS-MinGW-runtime', 'winpthreads/LICENSE.OpenBLAS-winpthreads'
)
foreach ($license in $licenses) {
    if ((Get-Item "install/share/licenses/$license").Length -eq 0) { throw "Empty notice: $license" }
}
if ((Test-Path install/lib/cmake) -or (Test-Path install/lib/pkgconfig)) { throw 'Build-local metadata retained' }
$cdx = Get-Content install/share/sbom/OpenBLAS.cdx.json -Raw | ConvertFrom-Json
$spdx = Get-Content install/share/sbom/OpenBLAS.spdx.json -Raw | ConvertFrom-Json
$url = "https://downloads.php.net/~windows/pecl/deps/OpenBLAS-$Version-$Vs-$Arch.zip"
if ($cdx.metadata.component.name -ne 'OpenBLAS' -or $cdx.metadata.component.version -ne $Version) { throw 'Incorrect CycloneDX root' }
if ($spdx.packages[0].name -ne 'OpenBLAS' -or $spdx.packages[0].versionInfo -ne $Version) { throw 'Incorrect SPDX root' }
if ($spdx.packages[0].downloadLocation -ne $url) { throw 'Incorrect SPDX download URL' }
if (($cdx.metadata.component.externalReferences | Where-Object type -eq distribution).url -notcontains $url) { throw 'Incorrect CycloneDX download URL' }
foreach ($property in @{ 'php:vs' = $Vs; 'php:arch' = $Arch; 'php:download-location' = $url }.GetEnumerator()) {
    if (($cdx.metadata.component.properties | Where-Object name -eq $property.Key).value -ne $property.Value) { throw "Incorrect $($property.Key)" }
}
$expected = @{ lapack = $(if ($Version -eq '0.3.18') { '3.9.0' } else { '3.12.0' }); 'gcc-runtime' = '9.3.0'; 'mingw-w64-runtime' = '7.0.0'; winpthreads = '7.0.0' }
foreach ($component in $expected.GetEnumerator()) {
    if (($cdx.components | Where-Object name -eq $component.Key).version -ne $component.Value) { throw "Incorrect CycloneDX component: $($component.Key)" }
    if (($spdx.packages | Where-Object name -eq $component.Key).versionInfo -ne $component.Value) { throw "Incorrect SPDX component: $($component.Key)" }
}
$notice = (Get-Content install/share/licenses/mingw-w64/LICENSE.OpenBLAS-MinGW-runtime -Raw).Trim()
if (($spdx.hasExtractedLicensingInfos | Where-Object licenseId -eq 'LicenseRef-MinGW-w64-runtime').extractedText -cne $notice) { throw 'Incomplete MinGW notice in SPDX' }
'PASS: eight license notices, complete runtime SBOM components, PECL URLs and package layout.' | Tee-Object validation/package.txt | Write-Host
$licenses | ForEach-Object { Get-FileHash "install/share/licenses/$_" } | Format-Table -AutoSize | Out-String | Add-Content validation/package.txt
