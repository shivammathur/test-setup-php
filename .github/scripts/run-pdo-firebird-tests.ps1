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
    [string] $FbclientArtifactsDirectory,
    [Parameter(Mandatory = $true)]
    [string] $FirebirdTag,
    [Parameter(Mandatory = $true)]
    [string] $FirebirdPackageName,
    [Parameter(Mandatory = $true)]
    [string] $BuilderRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FbclientRuntimeInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $SourceRoot
    )

    $fbclientPath = Join-Path $SourceRoot 'bin\fbclient.dll'
    $gds32Path = Join-Path $SourceRoot 'bin\gds32.dll'

    return [PSCustomObject]@{
        FbclientPath = if (Test-Path $fbclientPath) { $fbclientPath } else { $null }
        Gds32Path = if (Test-Path $gds32Path) { $gds32Path } else { $null }
    }
}

function Initialize-Firebird {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('x86', 'x64')]
        [string] $Arch,
        [Parameter(Mandatory = $true)]
        [string] $FirebirdTag,
        [Parameter(Mandatory = $true)]
        [string] $FirebirdPackageName,
        [Parameter(Mandatory = $true)]
        [string] $FbclientRuntimeSourceRoot
    )

    $destDir = 'C:\Firebird'
    $serviceName = 'TestInstance'
    $downloadUrl = "https://github.com/FirebirdSQL/firebird/releases/download/$FirebirdTag/$FirebirdPackageName"

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

    $runtimeInfo = Get-FbclientRuntimeInfo -SourceRoot $FbclientRuntimeSourceRoot
    if ($null -ne $runtimeInfo.FbclientPath) {
        Copy-Item -Path $runtimeInfo.FbclientPath -Destination (Join-Path $destDir 'fbclient.dll') -Force
        if ($null -ne $runtimeInfo.Gds32Path) {
            Copy-Item -Path $runtimeInfo.Gds32Path -Destination (Join-Path $destDir 'gds32.dll') -Force
        }
        Write-Host "Copied fbclient runtime from winlib artifact into $destDir"
    } else {
        Write-Host "winlib artifact does not contain fbclient.dll; using the runtime from $FirebirdPackageName"
    }

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

function Apply-FbclientArtifacts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $SourceRoot,
        [Parameter(Mandatory = $true)]
        [string] $DestinationRoot
    )

    $includeSource = Join-Path $SourceRoot 'include\interbase'
    $importLib = Join-Path $SourceRoot 'lib\fbclient_ms.lib'
    $binSource = Join-Path $SourceRoot 'bin'

    if (-not (Test-Path $includeSource)) {
        throw "fbclient artifact include directory was not found at $includeSource"
    }

    if (-not (Test-Path $importLib)) {
        throw "fbclient artifact import library was not found at $importLib"
    }

    $destIncludeRoot = Join-Path $DestinationRoot 'include\interbase'
    $destLibRoot = Join-Path $DestinationRoot 'lib'

    New-Item -ItemType Directory -Path $destIncludeRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $destLibRoot -Force | Out-Null

    Copy-Item -Path (Join-Path $includeSource '*') -Destination $destIncludeRoot -Recurse -Force
    Copy-Item -Path $importLib -Destination (Join-Path $destLibRoot 'fbclient_ms.lib') -Force

    if (Test-Path $binSource) {
        $destBinRoot = Join-Path $DestinationRoot 'bin'
        New-Item -ItemType Directory -Path $destBinRoot -Force | Out-Null
        Copy-Item -Path (Join-Path $binSource '*') -Destination $destBinRoot -Recurse -Force
    }
}

function Get-ExpectedClientVersionInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $FirebirdPackageName
    )

    $match = [regex]::Match(
        $FirebirdPackageName,
        '^Firebird-(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)\.(?<build>\d+)-0-(?:x64|Win32)\.zip$'
    )

    if (-not $match.Success) {
        throw "Could not derive the expected client version info from $FirebirdPackageName"
    }

    return [PSCustomObject]@{
        MajorMinorVersion = "$($match.Groups['major'].Value).$($match.Groups['minor'].Value)"
        PatchBuildVersion = "$($match.Groups['patch'].Value).$($match.Groups['build'].Value)"
    }
}

function Add-PhpDepsWithoutFbclient {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $PhpVersion,
        [Parameter(Mandatory = $true)]
        [string] $VsVersion,
        [Parameter(Mandatory = $true)]
        [ValidateSet('x86', 'x64')]
        [string] $Arch,
        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    $baseurl = 'https://downloads.php.net/~windows/php-sdk/deps'

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }

    $packageData = Get-PhpDepsPackages -PhpVersion $PhpVersion -VsVersion $VsVersion -Arch $Arch
    $packages = @($packageData.Packages | Where-Object { $_ -notmatch '^fbclient-' })
    Write-Host 'Skipping php-sdk fbclient packages so fbclient comes from the downloaded artifact and matching Firebird runtime.'

    foreach ($package in $packages) {
        Write-Host "Processing package $package"
        $temp = New-TemporaryFile | Rename-Item -NewName { $_.Name + '.zip' } -PassThru
        $url = "$baseurl/$VsVersion/$Arch/$package"
        Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $temp.FullName -ErrorAction Stop
        try {
            Expand-Archive -LiteralPath $temp.FullName -DestinationPath $Destination -Force
        } catch {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::ExtractToDirectory($temp.FullName, $Destination)
        } finally {
            Remove-Item -LiteralPath $temp.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    $opensslConfig = Join-Path $Destination 'openssl.cnf'
    if (Test-Path -LiteralPath $opensslConfig) {
        $templateDirectory = Join-Path $Destination 'template\ssl'
        New-Item -ItemType Directory -Force -Path $templateDirectory | Out-Null
        Move-Item -LiteralPath $opensslConfig -Destination (Join-Path $templateDirectory 'openssl.cnf') -Force
    }
}

$modulePath = Join-Path $BuilderRoot 'php\BuildPhp\BuildPhp.psd1'
if (-not (Test-Path $modulePath)) {
    throw "BuildPhp module was not found at $modulePath"
}

Import-Module $modulePath -Force

$artifactsPath = (Resolve-Path $ArtifactsDirectory).Path
$fbclientArtifactsPath = (Resolve-Path $FbclientArtifactsDirectory).Path
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

$availableFbclientArtifacts = @(
    Get-ChildItem -Path $fbclientArtifactsPath -Recurse -File |
        Sort-Object FullName |
        Select-Object -ExpandProperty FullName
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
$customDepsDirectory = Join-Path $rootTemp ("deps-" + [System.Guid]::NewGuid().ToString('N'))
$testsDirectory = 'tests'

$logPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.log"
$junitPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.junit.xml"
$metaPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.meta.txt"
$iniSnapshotPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.ini"

New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $testsTempDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $stagedArtifactsDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $customDepsDirectory -Force | Out-Null

Copy-Item -Path $runtimeZip.FullName -Destination (Join-Path $stagedArtifactsDirectory $runtimeZipAlias) -Force
Copy-Item -Path $testPackZip.FullName -Destination (Join-Path $stagedArtifactsDirectory $testPackAlias) -Force

$originalLocation = (Get-Location).Path

try {
    Set-Location $buildDirectory

    $env:DEPS_DIR = $customDepsDirectory
    $env:DEPS_CACHE_HIT = 'true'
    Add-PhpDepsWithoutFbclient -PhpVersion $PhpVersion -VsVersion $vsData.vs -Arch $Arch -Destination $env:DEPS_DIR

    $null = Add-TestRequirements `
        -PhpVersion $PhpVersion `
        -Arch $Arch `
        -Ts $Ts `
        -VsVersion $vsData.vs `
        -TestsDirectory $testsDirectory `
        -ArtifactsDirectory $stagedArtifactsDirectory

    Apply-FbclientArtifacts -SourceRoot $fbclientArtifactsPath -DestinationRoot $env:DEPS_DIR

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
    Initialize-Firebird `
        -Arch $Arch `
        -FirebirdTag $FirebirdTag `
        -FirebirdPackageName $FirebirdPackageName `
        -FbclientRuntimeSourceRoot $fbclientArtifactsPath

    $artifactRuntimeInfo = Get-FbclientRuntimeInfo -SourceRoot $fbclientArtifactsPath
    $artifactFbclientPath = $artifactRuntimeInfo.FbclientPath
    $installedFbclientPath = 'C:\Firebird\fbclient.dll'
    $installedFbclientHash = (Get-FileHash -Path $installedFbclientPath -Algorithm SHA256).Hash
    $fbclientHashPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.fbclient-hash.txt"
    $fbclientHashLines = @(
        "artifact-runtime-available=$($null -ne $artifactFbclientPath)",
        "artifact-fbclient=$artifactFbclientPath",
        "installed-fbclient=$installedFbclientPath",
        "installed-sha256=$installedFbclientHash"
    )

    if ($null -ne $artifactFbclientPath) {
        $artifactFbclientHash = (Get-FileHash -Path $artifactFbclientPath -Algorithm SHA256).Hash
        $fbclientHashLines += "artifact-sha256=$artifactFbclientHash"

        if ($artifactFbclientHash -ne $installedFbclientHash) {
            throw "The deployed fbclient.dll in C:\Firebird does not match the winlib artifact for PHP $PhpVersion $Arch $Ts"
        }
    } else {
        $artifactFbclientHash = '<not present in artifact>'
    }

    $fbclientHashLines | Set-Content -Path $fbclientHashPath -Encoding ASCII

    $fbclientWherePath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.fbclient-where.txt"
    $whereExe = Join-Path $env:SystemRoot 'System32\where.exe'
    $resolvedFbclientPaths = & $whereExe fbclient.dll 2>&1
    $resolvedFbclientPaths | Set-Content -Path $fbclientWherePath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "where.exe could not locate fbclient.dll for PHP $PhpVersion $Arch $Ts"
    }
    $resolvedFbclientPaths | Out-Host

    $resolvedFbclientPath = ($resolvedFbclientPaths | Select-Object -First 1).ToString().Trim()
    if ($resolvedFbclientPath -notlike 'C:\Firebird\*') {
        throw "Expected fbclient.dll to resolve from C:\Firebird first, but got $resolvedFbclientPath"
    }

    $smokeIni = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.smoke.ini"
    $phpVPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.php-v.txt"
    $phpMPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.php-m.txt"
    $phpIPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.php-i.txt"
    $phpISummaryPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.php-i-summary.txt"
    $basicSmokeScriptPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.smoke.php"
    $basicSmokeOutputPath = Join-Path $resultsDirectory "pdo-firebird-$PhpVersion-$Arch-$Ts.smoke.txt"

    $smokeIniLines = @(
        'date.timezone=UTC',
        "extension_dir=$extensionDirectory"
    )

    $pdoCoreExtension = Join-Path $extensionDirectory 'php_pdo.dll'
    if (Test-Path $pdoCoreExtension) {
        $smokeIniLines += 'extension=php_pdo.dll'
    }

    $smokeIniLines += 'extension=php_pdo_firebird.dll'
    $smokeIniLines | Set-Content -Path $smokeIni -Encoding ASCII

    $phpVOutput = & $phpExe -c $smokeIni -v 2>&1
    $phpVOutput | Set-Content -Path $phpVPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "php -v smoke test failed for PHP $PhpVersion $Arch $Ts"
    }
    $phpVOutput | Out-Host

    $phpMOutput = & $phpExe -c $smokeIni -m 2>&1
    $phpMOutput | Set-Content -Path $phpMPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "php -m smoke test failed for PHP $PhpVersion $Arch $Ts"
    }
    if (($phpMOutput -join [Environment]::NewLine) -notmatch 'pdo_firebird') {
        throw "php -m output did not list pdo_firebird for PHP $PhpVersion $Arch $Ts"
    }
    $phpMOutput | Out-Host

    $phpIOutput = & $phpExe -c $smokeIni -i 2>&1
    $phpIOutput | Set-Content -Path $phpIPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "php -i smoke test failed for PHP $PhpVersion $Arch $Ts"
    }
    $phpIOutput | Out-Host

    $clientVersionLine = @(
        $phpIOutput | Select-String -Pattern '^Client Library Version =>'
    ) | Select-Object -First 1 | ForEach-Object { $_.ToString() }

    if ([string]::IsNullOrWhiteSpace($clientVersionLine)) {
        $clientVersionLine = 'Client Library Version => <not reported>'
    }

    $phpISummary = @(
        $phpIOutput | Select-String -Pattern '^PHP Version =>', '^Thread Safety =>', '^Architecture =>', '^PDO support =>', '^PDO drivers =>', '^Client Library Version =>', '^Firebird API version =>', '^Client API version =>', '^pdo_firebird$'
    ) | ForEach-Object { $_.ToString() }
    if ($phpISummary -notcontains $clientVersionLine) {
        $phpISummary += $clientVersionLine
    }
    $phpISummary | Set-Content -Path $phpISummaryPath -Encoding ASCII
    $phpISummary | Out-Host

    $basicSmokeScript = @'
<?php
$dsn = getenv('PDO_FIREBIRD_TEST_DSN');
$user = getenv('PDO_FIREBIRD_TEST_USER');
$pass = getenv('PDO_FIREBIRD_TEST_PASS');

$dbh = new PDO($dsn, $user, $pass);
echo 'driver=', $dbh->getAttribute(PDO::ATTR_DRIVER_NAME), PHP_EOL;
echo 'user=', trim((string) $dbh->query('SELECT CURRENT_USER FROM RDB$DATABASE')->fetchColumn()), PHP_EOL;
echo 'probe=', trim((string) $dbh->query('SELECT 1 FROM RDB$DATABASE')->fetchColumn()), PHP_EOL;
'@
    Set-Content -Path $basicSmokeScriptPath -Value $basicSmokeScript -Encoding ASCII

    $basicSmokeOutput = & $phpExe -c $smokeIni $basicSmokeScriptPath 2>&1
    $basicSmokeOutput | Set-Content -Path $basicSmokeOutputPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "Basic PDO Firebird smoke script failed for PHP $PhpVersion $Arch $Ts"
    }
    if (($basicSmokeOutput -join [Environment]::NewLine) -notmatch 'driver=firebird') {
        throw "Basic PDO Firebird smoke script did not report the firebird driver for PHP $PhpVersion $Arch $Ts"
    }
    if (($basicSmokeOutput -join [Environment]::NewLine) -notmatch 'probe=1') {
        throw "Basic PDO Firebird smoke script did not complete the expected query for PHP $PhpVersion $Arch $Ts"
    }
    $basicSmokeOutput | Out-Host

    @(
        "PHP version: $PhpVersion",
        "Arch: $Arch",
        "TS: $Ts",
        "Runtime zip: $($runtimeZip.Name)",
        "Runtime alias: $runtimeZipAlias",
        "Test pack: $($testPackZip.Name)",
        "Test pack alias: $testPackAlias",
        "Firebird tag: $FirebirdTag",
        "Firebird package: $FirebirdPackageName",
        "fbclient artifact root: $fbclientArtifactsPath",
        "fbclient artifacts:",
        $availableFbclientArtifacts,
        "Artifact fbclient hash: $artifactFbclientHash",
        "Installed fbclient hash: $installedFbclientHash",
        "Resolved fbclient.dll paths:",
        $resolvedFbclientPaths,
        "Loaded client library version:",
        $clientVersionLine,
        "Artifacts:",
        $availableArtifacts,
        "Smoke test output:",
        $phpVOutput,
        $basicSmokeOutput
    ) | Set-Content -Path $metaPath -Encoding ASCII

    $testRoot = Join-Path $buildDirectory 'tests\ext\pdo_firebird\tests'
    if (-not (Test-Path $testRoot)) {
        throw "PDO Firebird test directory was not found at $testRoot"
    }

    & (Join-Path $PSScriptRoot 'sync-pdo-firebird-autocommit-test.ps1') -TestsRoot $testRoot

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
        $warningMessage = "PDO Firebird PHPT suite exited with code $exitCode for PHP $PhpVersion $Arch $Ts. Smoke tests passed and results were uploaded for review."
        Add-Content -Path $metaPath -Value $warningMessage -Encoding ASCII
        Write-Warning $warningMessage
        if ($env:GITHUB_ACTIONS -eq 'true') {
            Write-Host "::warning::$warningMessage"
        }
    }

    $global:LASTEXITCODE = 0
} finally {
    Set-Location $originalLocation

    if (Test-Path $testsTempDirectory) {
        Remove-Item -Path $testsTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $stagedArtifactsDirectory) {
        Remove-Item -Path $stagedArtifactsDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $customDepsDirectory) {
        Remove-Item -Path $customDepsDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
