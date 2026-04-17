[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $RequestedPhpVersion,
    [Parameter(Mandatory = $true)]
    [string] $ActualPhpVersion,
    [Parameter(Mandatory = $true)]
    [ValidateSet('nts', 'ts')]
    [string] $Ts,
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
        [ValidateSet('x64')]
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

$modulePath = Join-Path $BuilderRoot 'php\BuildPhp\BuildPhp.psd1'
if (-not (Test-Path $modulePath)) {
    throw "BuildPhp module was not found at $modulePath"
}

Import-Module $modulePath -Force

$privateHelpers = @(
    'Add-WindowsTestHelpers.ps1',
    'Invoke-CompatRunTestsPatch.ps1'
)

foreach ($helper in $privateHelpers) {
    $helperPath = Join-Path $BuilderRoot "php\BuildPhp\private\$helper"
    if (-not (Test-Path $helperPath)) {
        throw "Required helper script was not found at $helperPath"
    }

    . $helperPath
}

$fbclientArtifactsPath = (Resolve-Path $FbclientArtifactsDirectory).Path
$availableFbclientArtifacts = @(
    Get-ChildItem -Path $fbclientArtifactsPath -Recurse -File |
        Sort-Object FullName |
        Select-Object -ExpandProperty FullName
)

$resultsDirectory = Join-Path $env:GITHUB_WORKSPACE 'results'
New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null

Set-NetSecurityProtocolType

$phpCommand = Get-Command php -ErrorAction Stop
$phpExe = $phpCommand.Source
$phpRoot = Split-Path -Path $phpExe -Parent
$phpDbg = Join-Path $phpRoot 'phpdbg.exe'
$extensionDirectory = Join-Path $phpRoot 'ext'
$pdoFirebirdExtension = Join-Path $extensionDirectory 'php_pdo_firebird.dll'
$pdoCoreExtension = Join-Path $extensionDirectory 'php_pdo.dll'

if (-not (Test-Path $phpExe)) {
    throw "php.exe was not found at $phpExe"
}

if (-not (Test-Path $pdoFirebirdExtension)) {
    throw "php_pdo_firebird.dll was not found at $pdoFirebirdExtension"
}

$arch = 'x64'
$rootTemp = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) {
    [System.IO.Path]::GetTempPath()
} else {
    "$($env:SystemDrive)\"
}

$buildDirectory = Join-Path $rootTemp ("php-release-tests-" + [System.Guid]::NewGuid().ToString('N'))
$testsTempDirectory = Join-Path $rootTemp ("tests_tmp_" + [System.Guid]::NewGuid().ToString('N'))
$testsDirectory = 'tests'

$logPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.log"
$junitPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.junit.xml"
$metaPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.meta.txt"
$iniSnapshotPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.ini"

New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $testsTempDirectory -Force | Out-Null

$originalLocation = (Get-Location).Path

try {
    Set-Location $buildDirectory

    Get-PhpTestPack -PhpVersion $ActualPhpVersion -TestsDirectory $testsDirectory

    $testsDirectoryPath = Join-Path $buildDirectory $testsDirectory
    Add-WindowsTestHelpers -TestsDirectoryPath $testsDirectoryPath -Arch $arch

    $settings = Get-TestSettings -PhpVersion $RequestedPhpVersion
    $runnerPath = Join-Path $testsDirectoryPath 'run-tests.php'
    if (-not (Test-Path $runnerPath)) {
        throw "run-tests.php was not found at $runnerPath"
    }

    $compatPatchName = if ($settings.PSObject.Properties.Name -contains 'compatPatch') { $settings.compatPatch } else { '' }
    $compatPatchApplied = $true
    if (-not [string]::IsNullOrWhiteSpace($compatPatchName)) {
        $compatPatchPath = Join-Path $BuilderRoot "php\BuildPhp\config\run-tests\$compatPatchName"
        if (-not (Test-Path $compatPatchPath)) {
            throw "Compatibility run-tests patch not found at $compatPatchPath"
        }

        $compatPatchApplied = Invoke-CompatRunTestsPatch -Path $runnerPath -PatchPath $compatPatchPath
        if ($compatPatchApplied) {
            Write-Host "Applied compatibility run-tests patch ($compatPatchName) in $testsDirectoryPath"
        } else {
            $warningMessage = "Failed to patch the runner for handling worker crashes, defaulting to 2 workers."
            Write-Warning $warningMessage
            if ($env:GITHUB_ACTIONS -eq 'true') {
                Write-Host "::warning $warningMessage"
            }
        }
    }

    $testIni = Join-Path $buildDirectory 'php-test.ini'
    $testIniLines = @(
        'date.timezone=UTC',
        "extension_dir=$extensionDirectory"
    )

    if (Test-Path $pdoCoreExtension) {
        $testIniLines += 'extension=php_pdo.dll'
    }

    $testIniLines += 'extension=php_pdo_firebird.dll'
    $testIniLines | Set-Content -Path $testIni -Encoding ASCII
    Copy-Item -Path $testIni -Destination $iniSnapshotPath -Force

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
        -Arch $arch `
        -FirebirdTag $FirebirdTag `
        -FirebirdPackageName $FirebirdPackageName `
        -FbclientRuntimeSourceRoot $fbclientArtifactsPath

    $artifactRuntimeInfo = Get-FbclientRuntimeInfo -SourceRoot $fbclientArtifactsPath
    $artifactFbclientPath = $artifactRuntimeInfo.FbclientPath
    $installedFbclientPath = 'C:\Firebird\fbclient.dll'
    $installedFbclientHash = (Get-FileHash -Path $installedFbclientPath -Algorithm SHA256).Hash
    $fbclientHashPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.fbclient-hash.txt"
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
            throw "The deployed fbclient.dll in C:\Firebird does not match the winlib artifact for released PHP $RequestedPhpVersion $Ts"
        }
    } else {
        $artifactFbclientHash = '<not present in artifact>'
    }

    $fbclientHashLines | Set-Content -Path $fbclientHashPath -Encoding ASCII

    $fbclientWherePath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.fbclient-where.txt"
    $whereExe = Join-Path $env:SystemRoot 'System32\where.exe'
    $resolvedFbclientPaths = & $whereExe fbclient.dll 2>&1
    $resolvedFbclientPaths | Set-Content -Path $fbclientWherePath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "where.exe could not locate fbclient.dll for released PHP $RequestedPhpVersion $Ts"
    }
    $resolvedFbclientPaths | Out-Host

    $resolvedFbclientPath = ($resolvedFbclientPaths | Select-Object -First 1).ToString().Trim()
    if ($resolvedFbclientPath -notlike 'C:\Firebird\*') {
        throw "Expected fbclient.dll to resolve from C:\Firebird first, but got $resolvedFbclientPath"
    }

    $phpVPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.php-v.txt"
    $phpMPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.php-m.txt"
    $phpIPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.php-i.txt"
    $phpISummaryPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.php-i-summary.txt"
    $basicSmokeScriptPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.smoke.php"
    $basicSmokeOutputPath = Join-Path $resultsDirectory "pdo-firebird-release-$RequestedPhpVersion-$Ts.smoke.txt"

    $phpVOutput = & $phpExe -n -c $testIni -v 2>&1
    $phpVOutput | Set-Content -Path $phpVPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "php -v smoke test failed for released PHP $RequestedPhpVersion $Ts"
    }
    $phpVOutput | Out-Host

    $phpMOutput = & $phpExe -n -c $testIni -m 2>&1
    $phpMOutput | Set-Content -Path $phpMPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "php -m smoke test failed for released PHP $RequestedPhpVersion $Ts"
    }
    if (($phpMOutput -join [Environment]::NewLine) -notmatch 'pdo_firebird') {
        throw "php -m output did not list pdo_firebird for released PHP $RequestedPhpVersion $Ts"
    }
    $phpMOutput | Out-Host

    $phpIOutput = & $phpExe -n -c $testIni -i 2>&1
    $phpIOutput | Set-Content -Path $phpIPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "php -i smoke test failed for released PHP $RequestedPhpVersion $Ts"
    }
    $phpIOutput | Out-Host

    $clientVersionInfo = Get-ExpectedClientVersionInfo -FirebirdPackageName $FirebirdPackageName
    $clientVersionLine = @(
        $phpIOutput | Select-String -Pattern '^Client Library Version =>'
    ) | Select-Object -First 1 | ForEach-Object { $_.ToString() }

    if ([string]::IsNullOrWhiteSpace($clientVersionLine)) {
        throw "php -i did not report a Client Library Version line for released PHP $RequestedPhpVersion $Ts"
    }
    if ($clientVersionLine -notlike "*$($clientVersionInfo.PatchBuildVersion)*") {
        throw "php -i did not report the expected client build version for $FirebirdPackageName"
    }
    if ($clientVersionLine -notlike "*Firebird $($clientVersionInfo.MajorMinorVersion)*") {
        throw "php -i did not report the expected Firebird family for $FirebirdPackageName"
    }

    $phpISummary = @(
        $phpIOutput | Select-String -Pattern '^PHP Version =>', '^Thread Safety =>', '^Architecture =>', '^PDO support =>', '^PDO drivers =>', '^Client Library Version =>', '^Firebird API version =>', '^Client API version =>', '^pdo_firebird$'
    ) | ForEach-Object { $_.ToString() }
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

    $basicSmokeOutput = & $phpExe -n -c $testIni $basicSmokeScriptPath 2>&1
    $basicSmokeOutput | Set-Content -Path $basicSmokeOutputPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "Basic PDO Firebird smoke script failed for released PHP $RequestedPhpVersion $Ts"
    }
    if (($basicSmokeOutput -join [Environment]::NewLine) -notmatch 'driver=firebird') {
        throw "Basic PDO Firebird smoke script did not report the firebird driver for released PHP $RequestedPhpVersion $Ts"
    }
    if (($basicSmokeOutput -join [Environment]::NewLine) -notmatch 'probe=1') {
        throw "Basic PDO Firebird smoke script did not complete the expected query for released PHP $RequestedPhpVersion $Ts"
    }
    $basicSmokeOutput | Out-Host

    @(
        "Requested PHP version: $RequestedPhpVersion",
        "Actual PHP version: $ActualPhpVersion",
        "Arch: $arch",
        "TS: $Ts",
        "php.exe: $phpExe",
        "extension_dir: $extensionDirectory",
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
        "Compat patch applied: $compatPatchApplied",
        "Smoke test output:",
        $phpVOutput,
        $basicSmokeOutput
    ) | Set-Content -Path $metaPath -Encoding ASCII

    $testRoot = Join-Path $testsDirectoryPath 'ext\pdo_firebird\tests'
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
        '-c', $testIni
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

    Set-Location $testsDirectoryPath
    & $phpExe @params 2>&1 | Tee-Object -FilePath $logPath | Out-Host
    $exitCode = $LASTEXITCODE

    if (-not (Test-Path $junitPath)) {
        Add-Content -Path $metaPath -Value 'JUnit file was not generated.' -Encoding ASCII
    }

    if ($exitCode -ne 0) {
        throw "PDO Firebird tests failed with exit code $exitCode for released PHP $RequestedPhpVersion $Ts"
    }
} finally {
    Set-Location $originalLocation

    if (Test-Path $testsTempDirectory) {
        Remove-Item -Path $testsTempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $buildDirectory) {
        Remove-Item -Path $buildDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
