param(
  [Parameter(Mandatory = $true)]
  [string] $Package,

  [Parameter(Mandatory = $true)]
  [string] $Artifact,

  [Parameter(Mandatory = $true)]
  [string] $Ref,

  [Parameter(Mandatory = $true)]
  [string] $PhpTarget,

  [Parameter(Mandatory = $true)]
  [ValidateSet('x64', 'x86')]
  [string] $Arch,

  [Parameter(Mandatory = $true)]
  [ValidateSet('nts', 'ts')]
  [string] $Ts,

  [Parameter(Mandatory = $true)]
  [ValidatePattern('^v[sc]\d+$')]
  [string] $Vs,

  [Parameter(Mandatory = $true)]
  [string] $BuildDirectory,

  [Parameter(Mandatory = $false)]
  [string] $ArtifactsDirectory = 'artifacts',

  [Parameter(Mandatory = $false)]
  [string] $DestinationRoot = 'source-extension-artifacts'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string] $Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

$destination = Resolve-FullPath (Join-Path $DestinationRoot $Package)
New-Item -ItemType Directory -Force -Path $destination | Out-Null

if (Test-Path -LiteralPath $ArtifactsDirectory) {
  $packagedArtifacts = @(Get-ChildItem -LiteralPath $ArtifactsDirectory -File -Recurse -ErrorAction SilentlyContinue)
  if ($packagedArtifacts.Count -eq 0) {
    throw "Packaged artifacts directory for $Package is empty: $ArtifactsDirectory"
  }

  Copy-Item -Path (Join-Path $ArtifactsDirectory '*') -Destination $destination -Recurse -Force
  Remove-Item -LiteralPath $ArtifactsDirectory -Recurse -Force
  "Collected packaged artifacts for $Package"
  exit 0
}

$buildRoot = Resolve-FullPath $BuildDirectory
if (!(Test-Path -LiteralPath $buildRoot -PathType Container)) {
  throw "No build directory found for $Package at $buildRoot"
}

$extensionDll = Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter "php_$Artifact.dll" -File |
  Where-Object { $_.FullName -notmatch '[\\/]php-bin[\\/]ext[\\/]' } |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1

if ($null -eq $extensionDll) {
  throw "No built extension DLL found for $Package under $buildRoot"
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "zlib-rs-source-$Package-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
try {
  Copy-Item -LiteralPath $extensionDll.FullName -Destination $stagingRoot -Force

  $extensionPdb = Join-Path $extensionDll.DirectoryName "$($extensionDll.BaseName).pdb"
  if (Test-Path -LiteralPath $extensionPdb -PathType Leaf) {
    Copy-Item -LiteralPath $extensionPdb -Destination $stagingRoot -Force
  }

  Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter '*.dll' -File |
    Where-Object {
      $_.Name -notlike 'php_*.dll' -and
      $_.FullName -match '[\\/]deps[\\/]bin[\\/]'
    } |
    Sort-Object FullName -Unique |
    ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $stagingRoot -Force
      $pdb = Join-Path $_.DirectoryName "$($_.BaseName).pdb"
      if (Test-Path -LiteralPath $pdb -PathType Leaf) {
        Copy-Item -LiteralPath $pdb -Destination $stagingRoot -Force
      }
    }

  Get-ChildItem -LiteralPath $buildRoot -Recurse -Filter '*.xml' -File |
    Where-Object { $_.FullName -match '[\\/]deps[\\/]bin[\\/]' } |
    Sort-Object FullName -Unique |
    ForEach-Object {
      $configRoot = Join-Path $stagingRoot 'config'
      New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
      Copy-Item -LiteralPath $_.FullName -Destination $configRoot -Force
    }

  $zip = Join-Path $destination "php_$Package-$($Ref.ToLowerInvariant())-$PhpTarget-$Ts-$Vs-$Arch.zip"
  if (Test-Path -LiteralPath $zip -PathType Leaf) {
    Remove-Item -LiteralPath $zip -Force
  }
  Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $zip -Force
  "Created fallback source artifact $zip"
} finally {
  Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
