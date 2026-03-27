[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $BuilderRoot,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactsDirectory,
    [Parameter(Mandatory = $true)]
    [string] $PhpVersion,
    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,
    [Parameter(Mandatory = $true)]
    [string] $SanityScript
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

function Expand-ZipArchiveSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    try {
        Expand-Archive -Path $Path -DestinationPath $Destination -Force
    } catch {
        7z x $Path "-o$Destination" -y | Out-Null
    }
}

function Get-PhpBuildArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ArtifactsPath,
        [Parameter(Mandatory = $true)]
        [string] $Arch,
        [Parameter(Mandatory = $true)]
        [string] $Ts
    )

    $zipPattern = "php-*-$Arch.zip"
    $zipRegex = "^php-(.+?)(-nts)?-Win32-v[sc]\d+-${Arch}\.zip$"
    $matches = @(
        Get-ChildItem -Path $ArtifactsPath -Filter $zipPattern -File |
            Where-Object {
                $zipMatch = [regex]::Match($_.Name, $zipRegex, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $_.Name -notmatch '^php-(devel-pack|debug-pack|test-pack)-' -and
                $_.Name -notmatch '-src\.zip$' -and
                $zipMatch.Success -and
                (($Ts -eq 'nts') -eq $zipMatch.Groups[2].Success)
            } |
            Sort-Object Name
    )

    if (-not $matches) {
        throw "No PHP build archive matched arch=$Arch ts=$Ts in $ArtifactsPath."
    }

    if ($matches.Count -ne 1) {
        throw "Expected exactly one PHP build archive for arch=$Arch ts=$Ts, found $($matches.Count): $($matches.Name -join ', ')"
    }

    return $matches[0]
}

$builderModule = Join-Path $BuilderRoot 'php\BuildPhp'
$artifactsPath = (Resolve-Path $ArtifactsDirectory).Path
$suiteScriptPath = (Resolve-Path $SanityScript).Path
$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)

New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
Import-Module $builderModule -Force

$vsData = Get-VsVersion -PhpVersion $PhpVersion
if ([string]::IsNullOrWhiteSpace($vsData.vs)) {
    throw "Unable to determine Visual Studio toolset for PHP $PhpVersion."
}

$variants = @(
    @{ Arch = 'x64'; Ts = 'nts' },
    @{ Arch = 'x64'; Ts = 'ts' },
    @{ Arch = 'x86'; Ts = 'nts' },
    @{ Arch = 'x86'; Ts = 'ts' }
)

$failures = [System.Collections.Generic.List[string]]::new()

foreach ($variant in $variants) {
    $label = '{0}-{1}-{2}' -f $PhpVersion, $variant.Arch, $variant.Ts
    $workDirectory = Join-Path $env:RUNNER_TEMP ('windows-gd-e2e-' + [System.Guid]::NewGuid().ToString())
    $resultsDirectory = Join-Path $outputPath $label
    $depsDirectory = Join-Path $env:RUNNER_TEMP ('deps-{0}-{1}' -f $PhpVersion, $variant.Arch)
    $extractDirectory = Join-Path $workDirectory 'phpbin'

    New-Item -Path $workDirectory, $resultsDirectory -ItemType Directory -Force | Out-Null

    Push-Location $workDirectory
    try {
        try {
            Write-Host "::group::Preparing $label"
            $env:DEPS_DIR = $depsDirectory
            $env:DEPS_CACHE_HIT = ''

            Add-PhpDeps -PhpVersion $PhpVersion `
                        -VsVersion $vsData.vs `
                        -Arch $variant.Arch `
                        -Destination $depsDirectory

            $archive = Get-PhpBuildArchive -ArtifactsPath $artifactsPath -Arch $variant.Arch -Ts $variant.Ts
            Expand-ZipArchiveSafe -Path $archive.FullName -Destination $extractDirectory

            $phpExe = Join-Path $extractDirectory 'php.exe'
            if (-not (Test-Path $phpExe)) {
                throw "php.exe not found after extracting $($archive.Name)."
            }

            $extDirectory = Join-Path $extractDirectory 'ext'
            if (-not (Test-Path $extDirectory)) {
                throw "Extension directory not found in $($archive.Name)."
            }

            $iniPath = Join-Path $extractDirectory 'php.ini'
            Set-Content -Path $iniPath -Encoding ascii -Value @(
                ('extension_dir="{0}"' -f $extDirectory),
                'extension=php_curl.dll',
                'extension=php_exif.dll',
                'extension=php_gd.dll',
                'extension=php_intl.dll',
                'extension=php_mbstring.dll',
                'extension=php_openssl.dll',
                'extension=php_pdo_sqlite.dll',
                'extension=php_sqlite3.dll',
                'display_errors=1',
                'error_reporting=E_ALL',
                'memory_limit=-1',
                'date.timezone=UTC'
            )

            $versionLog = Join-Path $resultsDirectory 'php-version.txt'
            $modulesLog = Join-Path $resultsDirectory 'php-modules.txt'
            $suiteLog = Join-Path $resultsDirectory 'gd-custom-suite.log'
            $reportPath = Join-Path $resultsDirectory 'gd-custom-report.json'

            $env:Path = "$extractDirectory;$depsDirectory\bin;$env:SystemRoot\System32;$env:Path"

            & $phpExe -c $iniPath -v 2>&1 | Tee-Object -FilePath $versionLog | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "php -v failed for $label."
            }

            & $phpExe -c $iniPath -m 2>&1 | Tee-Object -FilePath $modulesLog | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "php -m failed for $label."
            }

            Write-Host "::endgroup::"
            Write-Host "::group::Running custom GD suite for $label"
            & $phpExe -c $iniPath $suiteScriptPath $label $reportPath 2>&1 | Tee-Object -FilePath $suiteLog | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "The custom GD suite failed for $label."
            }
        } finally {
            Write-Host "::endgroup::"
        }
    } catch {
        $message = $_.Exception.Message
        $failures.Add(('{0}: {1}' -f $label, $message))
        Write-Error $message
    } finally {
        Pop-Location
    }
}

if ($failures.Count -gt 0) {
    throw ("GD artifact e2e failures:`n - " + ($failures -join "`n - "))
}
