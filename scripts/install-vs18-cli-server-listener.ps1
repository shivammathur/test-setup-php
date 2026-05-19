param(
    [Parameter(Mandatory = $true)]
    [string] $BuilderRepoPath,
    [Parameter(Mandatory = $false)]
    [string] $DebugFilter = 'bug67198'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function ConvertTo-Lf {
    param([string] $Text)

    return (($Text -replace "`r`n", "`n") -replace "`r", "`n")
}

function Restore-Newlines {
    param(
        [string] $Text,
        [string] $Newline
    )

    return (ConvertTo-Lf -Text $Text) -replace "`n", $Newline
}

function ConvertTo-PowerShellSingleQuotedLiteral {
    param([string] $Text)

    return "'" + ($Text -replace "'", "''") + "'"
}

$invokePhpTests = Join-Path $BuilderRepoPath 'php\BuildPhp\public\Invoke-PhpTests.ps1'
if (-not (Test-Path -Path $invokePhpTests -PathType Leaf)) {
    throw "Invoke-PhpTests.ps1 not found: $invokePhpTests"
}

$rawContent = Get-Content -Path $invokePhpTests -Raw
$newline = if ($rawContent.Contains("`r`n")) { "`r`n" } else { "`n" }
$content = ConvertTo-Lf -Text $rawContent

if ($content -match 'Install-BuildPhpCliServerListener') {
    Write-Host "CLI server listener patch already present in $invokePhpTests"
    return
}

$debugFilterLiteral = ConvertTo-PowerShellSingleQuotedLiteral -Text $DebugFilter
$helper = ConvertTo-Lf -Text @"
function ConvertTo-BuildPhpCliServerPhpSingleQuotedLiteral {
    param([string] `$Text)

    return "'" + ((`$Text -replace '\\', '\\\\') -replace "'", "\\'") + "'"
}

function Install-BuildPhpCliServerListener {
    param(
        [Parameter(Mandatory = `$true)]
        [string] `$BuildDirectory,
        [Parameter(Mandatory = `$true)]
        [string] `$TestsDirectory,
        [Parameter(Mandatory = `$true)]
        [string] `$ArtifactsDirectory,
        [Parameter(Mandatory = `$true)]
        [string] `$Arch,
        [Parameter(Mandatory = `$true)]
        [string] `$Ts,
        [Parameter(Mandatory = `$true)]
        [string] `$Opcache,
        [Parameter(Mandatory = `$true)]
        [string] `$TestType
    )

    if (`$env:BUILD_PHP_CLI_SERVER_LISTENER -eq '0') {
        Write-Host 'CLI server listener disabled by BUILD_PHP_CLI_SERVER_LISTENER=0'
        return
    }

    `$helperPath = Join-Path `$BuildDirectory (Join-Path `$TestsDirectory 'sapi\cli\tests\php_cli_server.inc')
    if (-not (Test-Path -Path `$helperPath -PathType Leaf)) {
        Write-Warning "CLI server helper not found: `$helperPath"
        return
    }

    `$sourceExe = Join-Path `$BuildDirectory 'phpbin\php.exe'
    `$serverExe = Join-Path `$BuildDirectory 'phpbin\php-cli-server.exe'
    if (-not (Test-Path -Path `$sourceExe -PathType Leaf)) {
        Write-Warning "PHP executable not found for CLI server listener: `$sourceExe"
        return
    }
    Copy-Item -Path `$sourceExe -Destination `$serverExe -Force

    `$dumpDir = Join-Path `$ArtifactsDirectory "crash-dumps-`$Arch-`$Ts-`$Opcache-`$TestType"
    New-Item -Path `$dumpDir -ItemType Directory -Force | Out-Null

    `$procdumpCandidates = if (`$Arch -eq 'x86') {
        @(
            (Join-Path `$env:RUNNER_TEMP 'procdump\procdump.exe'),
            (Join-Path `$env:RUNNER_TEMP 'procdump\procdump64.exe')
        )
    } else {
        @(
            (Join-Path `$env:RUNNER_TEMP 'procdump\procdump64.exe'),
            (Join-Path `$env:RUNNER_TEMP 'procdump\procdump.exe')
        )
    }
    `$procdump = `$procdumpCandidates | Where-Object { `$_ -and (Test-Path -Path `$_ -PathType Leaf) } | Select-Object -First 1

    if (`$null -eq `$procdump) {
        Write-Warning 'ProcDump not found; CLI server live listener will be skipped.'
        `$procdump = ''
    }

    `$debugLogPath = Join-Path `$dumpDir 'cli-server-debug.log'
    `$filter = if ([string]::IsNullOrWhiteSpace(`$env:BUILD_PHP_CLI_SERVER_DEBUG_FILTER)) {
        $debugFilterLiteral
    } else {
        `$env:BUILD_PHP_CLI_SERVER_DEBUG_FILTER
    }

    `$werKey = 'HKCU:\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\php-cli-server.exe'
    try {
        New-Item -Path `$werKey -Force | Out-Null
        New-ItemProperty -Path `$werKey -Name DumpFolder -Value `$dumpDir -PropertyType ExpandString -Force | Out-Null
        New-ItemProperty -Path `$werKey -Name DumpCount -Value 8 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path `$werKey -Name DumpType -Value 2 -PropertyType DWord -Force | Out-Null
        Write-Host "CLI server WER dumps: `$dumpDir"
    } catch {
        Write-Warning "Unable to enable CLI server WER dumps: `$_"
    }

    `$rawHelper = Get-Content -Path `$helperPath -Raw
    `$helperNewline = if (`$rawHelper.Contains("``r``n")) { "``r``n" } else { "``n" }
    `$helperContent = ((`$rawHelper -replace "``r``n", "``n") -replace "``r", "``n")
    if (`$helperContent -match 'php_cli_server_debug_log') {
        Write-Host "CLI server live listener already present in `$helperPath"
        return
    }

    `$phpProcDumpPath = ConvertTo-BuildPhpCliServerPhpSingleQuotedLiteral -Text `$procdump
    `$phpDumpDir = ConvertTo-BuildPhpCliServerPhpSingleQuotedLiteral -Text `$dumpDir
    `$phpDebugFilter = ConvertTo-BuildPhpCliServerPhpSingleQuotedLiteral -Text `$filter
    `$phpDebugLogPath = ConvertTo-BuildPhpCliServerPhpSingleQuotedLiteral -Text `$debugLogPath

    `$oldIterator = @'
                `$iterator = new RecursiveIteratorIterator(
                    new RecursiveDirectoryIterator(`$dir, RecursiveDirectoryIterator::SKIP_DOTS)
                );
'@
    `$newIterator = @'
                `$iterator = new RecursiveIteratorIterator(
                    new RecursiveDirectoryIterator(`$dir, RecursiveDirectoryIterator::SKIP_DOTS),
                    RecursiveIteratorIterator::LEAVES_ONLY,
                    RecursiveIteratorIterator::CATCH_GET_CHILD
                );
'@
    if (`$helperContent.Contains(`$oldIterator)) {
        `$helperContent = `$helperContent.Replace(`$oldIterator, `$newIterator)
    }

    `$debugFunctions = @'
function php_cli_server_debug_log(string `$message): void
{
    `$log_file = __DEBUG_LOG_PATH__;

    @file_put_contents(
        `$log_file,
        date('c') . " " . `$message . PHP_EOL,
        FILE_APPEND
    );
}

function php_cli_server_debug_matches_filter(string `$test_script, string `$filter): bool
{
    `$test_name = basename(`$test_script, '.php');
    foreach (preg_split('/[;,]/', `$filter) as `$entry) {
        `$entry = trim(`$entry);
        if (`$entry !== '' && stripos(`$test_name, `$entry) !== false) {
            return true;
        }
    }

    return false;
}

function php_cli_server_debug_prepare(string `$php_executable, string `$doc_root): array
{
    `$result = [
        'server_executable' => `$php_executable,
        'watch_handle' => null,
    ];

    if (PHP_OS_FAMILY !== "Windows") {
        php_cli_server_debug_log('skip: non-Windows');
        return `$result;
    }

    `$test_script = (string) (`$_SERVER['PHP_SELF'] ?? '');
    `$filter = __DEBUG_FILTER__;
    php_cli_server_debug_log('prepare: self=' . `$test_script . ' filter=' . `$filter);
    if (`$filter !== '' && !php_cli_server_debug_matches_filter(`$test_script, `$filter)) {
        php_cli_server_debug_log('skip: filter mismatch');
        return `$result;
    }

    `$server_executable = dirname(`$php_executable) . DIRECTORY_SEPARATOR . 'php-cli-server.exe';
    if (is_file(`$server_executable)) {
        `$result['server_executable'] = `$server_executable;
    } else {
        `$server_executable = `$php_executable;
    }

    `$dump_dir = __DUMP_DIR__;
    if (!is_dir(`$dump_dir) && !@mkdir(`$dump_dir, 0777, true) && !is_dir(`$dump_dir)) {
        php_cli_server_debug_log('skip: dump dir unavailable ' . `$dump_dir);
        return `$result;
    }

    `$procdump = __PROCDUMP_PATH__;
    if (!`$procdump || !is_file(`$procdump)) {
        php_cli_server_debug_log('skip: ProcDump missing');
        return `$result;
    }

    `$null_device = PHP_OS_FAMILY === "Windows" ? 'NUL' : '/dev/null';
    `$descriptorspec = [
        0 => ['file', `$null_device, 'r'],
        1 => ['file', `$null_device, 'a'],
        2 => ['file', `$null_device, 'a'],
    ];

    `$watch_name = basename(`$server_executable);
    php_cli_server_debug_log('prepare: armed for script=' . `$test_script . ' watch=' . `$watch_name . ' dump_dir=' . `$dump_dir);
    `$watch_handle = @proc_open(
        [
            `$procdump,
            '-accepteula',
            '-ma',
            '-e',
            '1',
            '-w',
            `$watch_name,
            `$dump_dir,
        ],
        `$descriptorspec,
        `$pipes,
        `$doc_root,
        null,
        [
            "suppress_errors" => true,
            'create_new_console' => true,
        ]
    );

    php_cli_server_debug_log(
        'watch: executable=' . `$server_executable
        . ' handle=' . (is_resource(`$watch_handle) ? 'resource' : 'null')
    );
    if (is_resource(`$watch_handle)) {
        usleep(100000);
    }

    `$result['watch_handle'] = `$watch_handle;
    return `$result;
}

'@
    `$debugFunctions = `$debugFunctions.Replace('__PROCDUMP_PATH__', `$phpProcDumpPath)
    `$debugFunctions = `$debugFunctions.Replace('__DUMP_DIR__', `$phpDumpDir)
    `$debugFunctions = `$debugFunctions.Replace('__DEBUG_FILTER__', `$phpDebugFilter)
    `$debugFunctions = `$debugFunctions.Replace('__DEBUG_LOG_PATH__', `$phpDebugLogPath)

    `$startMarker = 'function php_cli_server_start('
    if (-not `$helperContent.Contains(`$startMarker)) {
        throw "Unable to locate php_cli_server_start() in `$helperPath"
    }
    `$helperContent = `$helperContent.Replace(`$startMarker, `$debugFunctions + `$startMarker)

    `$oldCommand = @'
    `$cmd = [`$php_executable, '-t', `$doc_root, '-n', ...`$cmd_args, '-S', 'localhost:0'];
'@
    `$newCommand = @'
    `$debug = php_cli_server_debug_prepare(`$php_executable, `$doc_root);
    `$server_php_executable = `$debug['server_executable'];
    `$debug_handle = `$debug['watch_handle'];

    `$cmd = [`$server_php_executable, '-t', `$doc_root, '-n', ...`$cmd_args, '-S', 'localhost:0'];
'@
    if (-not `$helperContent.Contains(`$oldCommand)) {
        throw "Unable to patch command block in `$helperPath"
    }
    `$helperContent = `$helperContent.Replace(`$oldCommand, `$newCommand)

    `$oldShutdown = @'
    register_shutdown_function(
        function(`$handle) use(`$router, `$doc_root, `$output_file) {
            proc_terminate(`$handle);
            `$status = proc_get_status(`$handle);
            if (`$status['exitcode'] !== -1 && `$status['exitcode'] !== 0
                    && !(`$status['exitcode'] === 255 && PHP_OS_FAMILY == 'Windows')) {
                printf("Server exited with non-zero status: %d\n", `$status['exitcode']);
                printf("Server output:\n%s\n", file_get_contents(`$output_file));
            }
            @unlink(__DIR__ . "/{`$router}");
            remove_directory(`$doc_root);
        },
        `$handle
    );
'@
    `$newShutdown = @'
    register_shutdown_function(
        function(`$handle, `$debug_handle) use(`$router, `$doc_root, `$output_file) {
            proc_terminate(`$handle);
            `$status = proc_get_status(`$handle);
            if (`$status['exitcode'] !== -1 && `$status['exitcode'] !== 0
                    && !(`$status['exitcode'] === 255 && PHP_OS_FAMILY == 'Windows')) {
                printf("Server exited with non-zero status: %d\n", `$status['exitcode']);
                printf("Server output:\n%s\n", file_get_contents(`$output_file));
            }
            if (is_resource(`$debug_handle)) {
                @proc_terminate(`$debug_handle);
            }
            @unlink(__DIR__ . "/{`$router}");
            remove_directory(`$doc_root);
        },
        `$handle,
        `$debug_handle
    );
'@
    if (-not `$helperContent.Contains(`$oldShutdown)) {
        throw "Unable to patch register_shutdown_function() block in `$helperPath"
    }
    `$helperContent = `$helperContent.Replace(`$oldShutdown, `$newShutdown)

    `$helperContent = `$helperContent -replace "``n", `$helperNewline
    Set-Content -Path `$helperPath -Value `$helperContent -NoNewline
    Write-Host "Installed CLI server listener in `$helperPath with filter '`$filter'"
}

"@

$content = $helper + $content

$callMarker = @'
        Set-PhpIniForTests -BuildDirectory $buildDirectory -Opcache $Opcache -TestType $TestType
'@
$callBlock = @'
        Install-BuildPhpCliServerListener -BuildDirectory $buildDirectory `
                                         -TestsDirectory $testsDirectory `
                                         -ArtifactsDirectory $currentDirectory `
                                         -Arch $Arch `
                                         -Ts $Ts `
                                         -Opcache $Opcache `
                                         -TestType $TestType

        Set-PhpIniForTests -BuildDirectory $buildDirectory -Opcache $Opcache -TestType $TestType
'@

if (-not $content.Contains($callMarker)) {
    throw "Unable to locate Invoke-PhpTests insertion point in $invokePhpTests"
}

$content = $content.Replace($callMarker, $callBlock)
Set-Content -Path $invokePhpTests -Value (Restore-Newlines -Text $content -Newline $newline) -NoNewline
Write-Host "Patched Invoke-PhpTests with CLI server listener: $invokePhpTests"
