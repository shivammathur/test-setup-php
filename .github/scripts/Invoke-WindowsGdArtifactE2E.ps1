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

$builderModule = Join-Path $BuilderRoot 'php\BuildPhp'
$artifactsPath = (Resolve-Path $ArtifactsDirectory).Path
$sanityScriptPath = (Resolve-Path $SanityScript).Path
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

foreach ($variant in $variants) {
    $label = '{0}-{1}-{2}' -f $PhpVersion, $variant.Arch, $variant.Ts
    $workDirectory = Join-Path $env:RUNNER_TEMP ('windows-gd-e2e-' + [System.Guid]::NewGuid().ToString())
    $resultsDirectory = Join-Path $outputPath $label
    $tmpDirectory = Join-Path $workDirectory 'tmp'
    $depsDirectory = Join-Path $env:RUNNER_TEMP ('deps-{0}-{1}' -f $PhpVersion, $variant.Arch)

    New-Item -Path $workDirectory, $resultsDirectory, $tmpDirectory -ItemType Directory -Force | Out-Null

    Write-Host "::group::Preparing $label"
    Push-Location $workDirectory
    try {
        $env:DEPS_DIR = $depsDirectory
        $env:DEPS_CACHE_HIT = ''

        Add-TestRequirements -PhpVersion $PhpVersion `
                             -Arch $variant.Arch `
                             -Ts $variant.Ts `
                             -VsVersion $vsData.vs `
                             -TestsDirectory 'tests' `
                             -ArtifactsDirectory $artifactsPath | Out-Null

        Set-PhpIniForTests -BuildDirectory $workDirectory -Opcache 'nocache'

        $iniPath = Join-Path $workDirectory 'phpbin\php.ini'
        Add-Content -Path $iniPath -Encoding ascii -Value @(
            'extension=php_exif.dll',
            'extension=php_xml.dll',
            'extension=php_dom.dll',
            'extension=php_simplexml.dll',
            'extension=php_xmlreader.dll',
            'extension=php_xmlwriter.dll',
            'extension=php_gd.dll',
            'date.timezone=UTC'
        )

        $phpExe = Join-Path $workDirectory 'phpbin\php.exe'
        $phpDbg = Join-Path $workDirectory 'phpbin\phpdbg.exe'
        $versionLog = Join-Path $resultsDirectory 'php-version.txt'
        $modulesLog = Join-Path $resultsDirectory 'php-modules.txt'
        $sanityLog = Join-Path $resultsDirectory 'gd-sanity.log'
        $phptLog = Join-Path $resultsDirectory 'gd-phpt.log'
        $junitPath = Join-Path $resultsDirectory 'gd-phpt.junit.xml'

        $env:Path = "$($workDirectory)\phpbin;$depsDirectory\bin;$env:SystemRoot\System32;$env:Path"
        $env:TEST_PHP_EXECUTABLE = $phpExe
        if (Test-Path $phpDbg) {
            $env:TEST_PHPDBG_EXECUTABLE = $phpDbg
        } else {
            Remove-Item Env:TEST_PHPDBG_EXECUTABLE -ErrorAction Ignore
        }
        $env:TEST_PHP_JUNIT = $junitPath
        $env:SKIP_IO_CAPTURE_TESTS = '1'
        $env:NO_INTERACTION = '1'
        $env:REPORT_EXIT_STATUS = '1'

        & $phpExe -c $iniPath -v 2>&1 | Tee-Object -FilePath $versionLog | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "php -v failed for $label."
        }

        & $phpExe -c $iniPath -m 2>&1 | Tee-Object -FilePath $modulesLog | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "php -m failed for $label."
        }

        & $phpExe -c $iniPath $sanityScriptPath 2>&1 | Tee-Object -FilePath $sanityLog | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "The GD sanity script failed for $label."
        }

        Write-Host "::endgroup::"
        Write-Host "::group::Running ext/gd PHPT suite for $label"
        Push-Location (Join-Path $workDirectory 'tests')
        try {
            $runTestsArgs = @(
                '-d', 'open_basedir=',
                '-d', 'output_buffering=0',
                'run-tests.php',
                '--no-progress',
                '-g', 'FAIL,BORK,WARN,LEAK',
                '-q',
                '--offline',
                '--show-diff',
                '--show-slow', '1000',
                '--set-timeout', '300',
                '--temp-source', $tmpDirectory,
                '--temp-target', $tmpDirectory,
                'ext/gd/tests'
            )

            & $phpExe @runTestsArgs 2>&1 | Tee-Object -FilePath $phptLog | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "The ext/gd PHPT suite failed for $label."
            }
        } finally {
            Pop-Location
            Write-Host "::endgroup::"
        }
    } finally {
        Pop-Location
    }
}
