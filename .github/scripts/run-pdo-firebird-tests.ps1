[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $PhpVersion,
    [Parameter(Mandatory = $true)]
    [ValidateSet('x86', 'x64')]
    [string] $Arch,
    [Parameter(Mandatory = $true)]
    [ValidateSet('nts', 'ts')]
    [string] $Ts,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactsDirectory,
    [Parameter(Mandatory = $true)]
    [string] $BuilderRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-Firebird {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('x86', 'x64')]
        [string] $Arch
    )

    $destDir = 'C:\Firebird'
    $serviceName = 'TestInstance'
    $firebirdVersion = 'v4.0.4'
    $firebirdRelease = "https://github.com/FirebirdSQL/firebird/releases/download/$firebirdVersion"
    $downloadUrl = if ($Arch -eq 'x64') {
        "$firebirdRelease/Firebird-4.0.4.3010-0-x64.zip"
    } else {
        "$firebirdRelease/Firebird-4.0.4.3010-0-Win32.zip"
    }

    if (Test-Path $destDir) {
        Remove-Item -Path $destDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $destDir -Force | Out-Null

    $zipPath = Join-Path $destDir 'Firebird.zip'
    Invoke-WebRequest -Uri $downloadUrl -UseBasicParsing -OutFile $zipPath

    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $destDir -Force
    } catch {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $destDir)
    }

    Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue

    $env:PDO_FIREBIRD_TEST_DATABASE = 'C:\test.fdb'
    $env:PDO_FIREBIRD_TEST_DSN = "firebird:dbname=127.0.0.1:$($env:PDO_FIREBIRD_TEST_DATABASE)"
    $env:PDO_FIREBIRD_TEST_USER = 'SYSDBA'
    $env:PDO_FIREBIRD_TEST_PASS = 'phpfi'

    if (Test-Path $env:PDO_FIREBIRD_TEST_DATABASE) {
        Remove-Item -Path $env:PDO_FIREBIRD_TEST_DATABASE -Force
    }

    $createUserSql = Join-Path $destDir 'create_user.sql'
    Set-Content -Path $createUserSql -Value "create user $($env:PDO_FIREBIRD_TEST_USER) password '$($env:PDO_FIREBIRD_TEST_PASS)';" -Encoding ASCII
    Add-Content -Path $createUserSql -Value 'commit;' -Encoding ASCII

    $setupSql = Join-Path $destDir 'setup.sql'
    Set-Content -Path $setupSql -Value "create database '$($env:PDO_FIREBIRD_TEST_DATABASE)' user '$($env:PDO_FIREBIRD_TEST_USER)' password '$($env:PDO_FIREBIRD_TEST_PASS)';" -Encoding ASCII

    & (Join-Path $destDir 'instsvc.exe') install -n $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install Firebird service for $Arch."
    }

    & (Join-Path $destDir 'isql') -q -i $setupSql | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create Firebird database for $Arch."
    }

    & (Join-Path $destDir 'isql') -q -i $createUserSql -user sysdba $env:PDO_FIREBIRD_TEST_DATABASE | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create Firebird test user for $Arch."
    }

    & (Join-Path $destDir 'instsvc.exe') start -n $serviceName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start Firebird service for $Arch."
    }

    Add-Path $destDir
}

$modulePath = Join-Path $BuilderRoot 'php\BuildPhp\BuildPhp.psd1'
if (-not (Test-Path $modulePath)) {
    throw "BuildPhp module was not found at $modulePath"
}

Import-Module $modulePath -Force

$artifactsPath = (Resolve-Path $ArtifactsDirectory).Path
$resultsDirectory = Join-Path $env:GITHUB_WORKSPACE 'results'
New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null

Set-NetSecurityProtocolType

$vsData = Get-VsVersion -PhpVersion $PhpVersion
if ($null -eq $vsData.vs) {
    throw "PHP version $PhpVersion is not supported."
}

$tsPart = if ($Ts -eq 'nts') { 'nts-Win32' } else { 'Win32' }
$runtimeZipAlias = "php-$PhpVersion-$tsPart-$($vsData.vs)-$Arch.zip"
$testPackAlias = "php-test-pack-$PhpVersion.zip"

$availableArtifacts = @(
    Get-ChildItem -Path $artifactsPath -File |
        Sort-Object Name |
        Select-Object -ExpandProperty Name
)

$runtimePattern = if ($Ts -eq 'nts') {
    "^php-.*-nts-Win32-$([regex]::Escape($vsData.vs))-$([regex]::Escape($Arch))\.zip$"
} else {
    "^php-.*-Win32-$([regex]::Escape($vsData.vs))-$([regex]::Escape($Arch))\.zip$"
}

$runtimeZip = Get-ChildItem -Path $artifactsPath -File |
    Where-Object {
        $_.Name -match $runtimePattern -and
        $_.Name -notmatch 'debug|devel|src' -and
        ($Ts -eq 'nts' -or $_.Name -notmatch '-nts-Win32-')
    } |
    Sort-Object Name |
    Select-Object -First 1

if ($null -eq $runtimeZip) {
    throw "A runtime zip matching $Ts/$($vsData.vs)/$Arch was not found in $artifactsPath. Available files: $($availableArtifacts -join ', ')"
}

$testPackZip = Get-ChildItem -Path $artifactsPath -File |
    Where-Object { $_.Name -match '^php-test-pack-.*\.zip$' } |
    Sort-Object Name |
    Select-Object -First 1

if ($null -eq $testPackZip) {
    throw "A php-test-pack zip was not found in $artifactsPath. Available files: $($availableArtifacts -join ', ')"
}

$rootTemp = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) {
    [System.IO.Path]::GetTempPath()
} else {
    "$($env:SystemDrive)\"
}

$buildDirectory = Join-Path $rootTemp ("php-" + [System.Guid]::NewGuid().ToString())
$testsTempDirectory = Join-Path $rootTemp ("tests_tmp_" + [System.Guid]::NewGuid().ToString('N'))
$stagedArtifactsDirectory = Join-Path $rootTemp ("builder-artifacts-" + [System.Guid]::NewGuid().ToString('N'))
$testsDirectory = 'tests'

$logPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.log"
$junitPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.junit.xml"
$metaPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.meta.txt"
$iniSnapshotPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.ini"

New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $testsTempDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $stagedArtifactsDirectory -Force | Out-Null

Copy-Item -Path $runtimeZip.FullName -Destination (Join-Path $stagedArtifactsDirectory $runtimeZipAlias) -Force
Copy-Item -Path $testPackZip.FullName -Destination (Join-Path $stagedArtifactsDirectory $testPackAlias) -Force

$originalLocation = (Get-Location).Path

try {
    Set-Location $buildDirectory

    $null = Add-TestRequirements `
        -PhpVersion $PhpVersion `
        -Arch $Arch `
        -Ts $Ts `
        -VsVersion $vsData.vs `
        -TestsDirectory $testsDirectory `
        -ArtifactsDirectory $stagedArtifactsDirectory

    $phpExe = Join-Path $buildDirectory 'phpbin\php.exe'
    $phpDbg = Join-Path $buildDirectory 'phpbin\phpdbg.exe'
    $phpIni = Join-Path $buildDirectory 'phpbin\php.ini'
    $extensionDirectory = Join-Path $buildDirectory 'phpbin\ext'
    $pdoFirebirdExtension = Join-Path $extensionDirectory 'php_pdo_firebird.dll'

    if (-not (Test-Path $phpExe)) {
        throw "php.exe was not extracted from $($runtimeZip.Name)"
    }

    if (-not (Test-Path $pdoFirebirdExtension)) {
        throw "php_pdo_firebird.dll was not extracted from $($runtimeZip.Name)"
    }

    Set-PhpIniForTests -BuildDirectory $buildDirectory -Opcache 'nocache' -TestType 'ext'
    Copy-Item -Path $phpIni -Destination $iniSnapshotPath -Force

    $env:Path = "$buildDirectory\phpbin;$env:Path"
    $env:TEST_PHP_EXECUTABLE = $phpExe
    if (Test-Path $phpDbg) {
        $env:TEST_PHPDBG_EXECUTABLE = $phpDbg
    }
    $env:TEST_PHP_JUNIT = $junitPath
    $env:SKIP_IO_CAPTURE_TESTS = '1'
    $env:NO_INTERACTION = '1'
    $env:REPORT_EXIT_STATUS = '1'

    Add-Path -Path "$env:SystemRoot\System32"
    Initialize-Firebird -Arch $Arch

    $smokeArgs = @(
        '-n',
        '-d', "extension_dir=$extensionDirectory"
    )

    $pdoCoreExtension = Join-Path $extensionDirectory 'php_pdo.dll'
    if (Test-Path $pdoCoreExtension) {
        $smokeArgs += @('-d', 'extension=php_pdo.dll')
    }

    $smokeArgs += @(
        '-d', 'extension=php_pdo_firebird.dll',
        '-r', "echo PHP_VERSION, ' ', PHP_ZTS ? 'TS' : 'NTS', PHP_EOL, 'pdo_firebird=', (int)extension_loaded('pdo_firebird');"
    )

    $smokeOutput = & $phpExe @smokeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "PDO Firebird smoke test failed for PHP $PhpVersion $Arch $Ts"
    }

    @(
        "PHP version: $PhpVersion",
        "Arch: $Arch",
        "TS: $Ts",
        "Runtime zip: $($runtimeZip.Name)",
        "Runtime alias: $runtimeZipAlias",
        "Test pack: $($testPackZip.Name)",
        "Test pack alias: $testPackAlias",
        "Artifacts:",
        $availableArtifacts,
        "Smoke test output:",
        $smokeOutput
    ) | Set-Content -Path $metaPath -Encoding ASCII

    $testRoot = Join-Path $buildDirectory 'tests\ext\pdo_firebird\tests'
    if (-not (Test-Path $testRoot)) {
        throw "PDO Firebird test directory was not found at $testRoot"
    }

    $tests = @(
        Get-ChildItem -Path $testRoot -Filter '*.phpt' -Recurse |
            Sort-Object FullName
    )

    if ($tests.Count -eq 0) {
        throw "No PDO Firebird tests were found in $testRoot"
    }

    Add-Content -Path $metaPath -Value "Test count: $($tests.Count)" -Encoding ASCII

    $testListPath = Join-Path $buildDirectory 'pdo-firebird-tests-to-run.txt'
    $tests.FullName | Set-Content -Path $testListPath -Encoding ASCII

    $settings = Get-TestSettings -PhpVersion $PhpVersion

    $testsBaseDirectory = Join-Path $buildDirectory 'tests'
    $runnerPath = Join-Path $buildDirectory 'tests\run-tests.php'
    if (-not (Test-Path $runnerPath)) {
        throw "run-tests.php was not found at $runnerPath"
    }

    $params = @(
        '-n',
        '-d', 'open_basedir=',
        '-d', 'output_buffering=0'
    )

    if (-not [string]::IsNullOrWhiteSpace($settings.runner)) {
        $params += $runnerPath
    }

    $params += @(
        '-p', $phpExe,
        '-n',
        '-c', $phpIni
    )

    if (-not [string]::IsNullOrWhiteSpace($settings.progress)) {
        $params += $settings.progress
    }

    $params += @(
        '-g', 'FAIL,BORK,WARN,LEAK',
        '-q',
        '--offline',
        '--show-diff',
        '--show-slow', '1000',
        '--set-timeout', '300',
        '--temp-source', $testsTempDirectory,
        '--temp-target', $testsTempDirectory,
        '-r', $testListPath
    )

    Set-Location $testsBaseDirectory
    & $phpExe @params 2>&1 | Tee-Object -FilePath $logPath | Out-Host
    $exitCode = $LASTEXITCODE

    if (-not (Test-Path $junitPath)) {
        Add-Content -Path $metaPath -Value 'JUnit file was not generated.' -Encoding ASCII
    }

    if ($exitCode -ne 0) {
        throw "PDO Firebird tests failed with exit code $exitCode for PHP $PhpVersion $Arch $Ts"
    }
} finally {
    Set-Location $originalLocation

    if (Test-Path $testsTempDirectory) {
        Remove-Item -Path $testsTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $stagedArtifactsDirectory) {
        Remove-Item -Path $stagedArtifactsDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
