param(
    [Parameter(Mandatory = $true)]
    [string] $BuilderRepoPath,
    [Parameter(Mandatory = $true)]
    [string] $ArtifactsDir,
    [Parameter(Mandatory = $true)]
    [string] $ResultsDir,
    [Parameter(Mandatory = $true)]
    [string] $OutputDir,
    [Parameter(Mandatory = $true)]
    [string] $PhpVersion,
    [Parameter(Mandatory = $true)]
    [ValidateSet('x86', 'x64')]
    [string] $Arch,
    [Parameter(Mandatory = $true)]
    [ValidateSet('ts', 'nts')]
    [string] $Ts,
    [Parameter(Mandatory = $true)]
    [ValidateSet('opcache', 'nocache')]
    [string] $Opcache,
    [Parameter(Mandatory = $true)]
    [ValidateSet('php', 'ext')]
    [string] $TestType,
    [Parameter(Mandatory = $true)]
    [string] $SourceRepository,
    [Parameter(Mandatory = $true)]
    [string] $SourceRef,
    [Parameter(Mandatory = $true)]
    [string] $ProcDumpPath,
    [Parameter(Mandatory = $false)]
    [string] $CdbPath = '',
    [Parameter(Mandatory = $false)]
    [bool] $RunFullSuite = $true,
    [Parameter(Mandatory = $false)]
    [int] $StressIterations = 120
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Section {
    param([string] $Message)
    Write-Host ''
    Write-Host "===== $Message ====="
}

function Get-PhpDebugPackPath {
    $tsPart = if ($Ts -eq 'nts') { 'nts-Win32' } else { 'Win32' }
    $fileName = "php-debug-pack-$PhpVersion-$tsPart-vs18-$Arch.zip"
    return Join-Path $ArtifactsDir $fileName
}

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

function ConvertTo-PhpSingleQuotedLiteral {
    param([string] $Text)

    return "'" + (($Text -replace '\\', '\\\\') -replace "'", "\\'") + "'"
}

function Set-CliServerDumpCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $DumpDir,
        [Parameter(Mandatory = $true)]
        [string] $ProcDumpExe,
        [Parameter(Mandatory = $true)]
        [string] $DebugFilter,
        [Parameter(Mandatory = $true)]
        [string] $DebugLogPath
    )

    $rawContent = Get-Content -Path $Path -Raw
    $newline = if ($rawContent.Contains("`r`n")) { "`r`n" } else { "`n" }
    $content = ConvertTo-Lf -Text $rawContent
    if ($content -match 'php_cli_server_debug_log') {
        Write-Host "CLI server dump capture patch already present in $Path"
        return
    }

    $phpProcDumpPath = ConvertTo-PhpSingleQuotedLiteral -Text $ProcDumpExe
    $phpDumpDir = ConvertTo-PhpSingleQuotedLiteral -Text $DumpDir
    $phpDebugFilter = ConvertTo-PhpSingleQuotedLiteral -Text $DebugFilter
    $phpDebugLogPath = ConvertTo-PhpSingleQuotedLiteral -Text $DebugLogPath

    $oldIterator = ConvertTo-Lf -Text @'
                $iterator = new RecursiveIteratorIterator(
                    new RecursiveDirectoryIterator($dir, RecursiveDirectoryIterator::SKIP_DOTS)
                );
'@
    $newIterator = ConvertTo-Lf -Text @'
                $iterator = new RecursiveIteratorIterator(
                    new RecursiveDirectoryIterator($dir, RecursiveDirectoryIterator::SKIP_DOTS),
                    RecursiveIteratorIterator::LEAVES_ONLY,
                    RecursiveIteratorIterator::CATCH_GET_CHILD
                );
'@
    if ($content.Contains($oldIterator)) {
        $content = $content.Replace($oldIterator, $newIterator)
    }

    $debugFunctions = ConvertTo-Lf -Text @'
function php_cli_server_debug_log(string $message): void
{
    $log_file = __DEBUG_LOG_PATH__;

    @file_put_contents(
        $log_file,
        date('c') . " " . $message . PHP_EOL,
        FILE_APPEND
    );
}

function php_cli_server_debug_matches_filter(string $test_script, string $filter): bool
{
    $test_name = basename($test_script, '.php');
    foreach (preg_split('/[;,]/', $filter) as $entry) {
        $entry = trim($entry);
        if ($entry !== '' && stripos($test_name, $entry) !== false) {
            return true;
        }
    }

    return false;
}

function php_cli_server_debug_prepare(string $php_executable, string $doc_root): array
{
    $result = [
        'server_executable' => $php_executable,
        'watch_handle' => null,
    ];

    if (PHP_OS_FAMILY !== "Windows") {
        php_cli_server_debug_log('skip: non-Windows');
        return $result;
    }

    $test_script = (string) ($_SERVER['PHP_SELF'] ?? '');
    $filter = __DEBUG_FILTER__;
    php_cli_server_debug_log('prepare: self=' . $test_script . ' filter=' . $filter);
    if ($filter !== '' && !php_cli_server_debug_matches_filter($test_script, $filter)) {
        php_cli_server_debug_log('skip: filter mismatch');
        return $result;
    }

    $server_executable = dirname($php_executable) . DIRECTORY_SEPARATOR . 'php-cli-server.exe';
    if (is_file($server_executable)) {
        $result['server_executable'] = $server_executable;
    } else {
        $server_executable = $php_executable;
    }

    $dump_dir = __DUMP_DIR__;
    if (!is_dir($dump_dir) && !@mkdir($dump_dir, 0777, true) && !is_dir($dump_dir)) {
        php_cli_server_debug_log('skip: dump dir unavailable ' . $dump_dir);
        return $result;
    }

    $procdump = __PROCDUMP_PATH__;
    if (!$procdump || !is_file($procdump)) {
        php_cli_server_debug_log('skip: ProcDump missing');
        return $result;
    }

    $null_device = PHP_OS_FAMILY === "Windows" ? 'NUL' : '/dev/null';
    $descriptorspec = [
        0 => ['file', $null_device, 'r'],
        1 => ['file', $null_device, 'a'],
        2 => ['file', $null_device, 'a'],
    ];

    $watch_name = basename($server_executable);
    php_cli_server_debug_log('prepare: armed for script=' . $test_script . ' watch=' . $watch_name . ' dump_dir=' . $dump_dir);
    $watch_handle = @proc_open(
        [
            $procdump,
            '-accepteula',
            '-ma',
            '-e',
            '1',
            '-w',
            $watch_name,
            $dump_dir,
        ],
        $descriptorspec,
        $pipes,
        $doc_root,
        null,
        [
            "suppress_errors" => true,
            'create_new_console' => true,
        ]
    );

    php_cli_server_debug_log(
        'watch: executable=' . $server_executable
        . ' handle=' . (is_resource($watch_handle) ? 'resource' : 'null')
    );
    if (is_resource($watch_handle)) {
        usleep(100000);
    }

    $result['watch_handle'] = $watch_handle;
    return $result;
}

'@
    $debugFunctions = $debugFunctions.Replace('__PROCDUMP_PATH__', $phpProcDumpPath)
    $debugFunctions = $debugFunctions.Replace('__DUMP_DIR__', $phpDumpDir)
    $debugFunctions = $debugFunctions.Replace('__DEBUG_FILTER__', $phpDebugFilter)
    $debugFunctions = $debugFunctions.Replace('__DEBUG_LOG_PATH__', $phpDebugLogPath)
    $startMarker = 'function php_cli_server_start('
    if (-not $content.Contains($startMarker)) {
        throw "Unable to locate php_cli_server_start() in $Path"
    }
    $content = $content.Replace($startMarker, $debugFunctions + $startMarker)

    $oldCommand = ConvertTo-Lf -Text @'
    $cmd = [$php_executable, '-t', $doc_root, '-n', ...$cmd_args, '-S', 'localhost:0'];
'@
    $newCommand = ConvertTo-Lf -Text @'
    $debug = php_cli_server_debug_prepare($php_executable, $doc_root);
    $server_php_executable = $debug['server_executable'];
    $debug_handle = $debug['watch_handle'];

    $cmd = [$server_php_executable, '-t', $doc_root, '-n', ...$cmd_args, '-S', 'localhost:0'];
'@
    if (-not $content.Contains($oldCommand)) {
        throw "Unable to patch command block in $Path"
    }
    $content = $content.Replace($oldCommand, $newCommand)

    $oldProcOpen = ConvertTo-Lf -Text @'
    $handle = proc_open($cmd, $descriptorspec, $pipes, $doc_root, null, array("suppress_errors" => true));
    if ($handle === false) {
        echo php_cli_server_failure_diagnostics("Server failed to start", $cmd, $doc_root, $handle, $output_file, $php_executable, false);
        exit(1);
    }
'@
    $newProcOpen = ConvertTo-Lf -Text @'
    $handle = proc_open($cmd, $descriptorspec, $pipes, $doc_root, null, array("suppress_errors" => true));
    if ($handle === false) {
        echo php_cli_server_failure_diagnostics("Server failed to start", $cmd, $doc_root, $handle, $output_file, $php_executable, false);
        exit(1);
    }
'@
    if (-not $content.Contains($oldProcOpen)) {
        throw "Unable to patch proc_open() block in $Path"
    }
    $content = $content.Replace($oldProcOpen, $newProcOpen)

    $oldShutdown = ConvertTo-Lf -Text @'
    register_shutdown_function(
        function($handle) use($router, $doc_root, $output_file) {
            proc_terminate($handle);
            $status = proc_get_status($handle);
            if ($status['exitcode'] !== -1 && $status['exitcode'] !== 0
                    && !($status['exitcode'] === 255 && PHP_OS_FAMILY == 'Windows')) {
                printf("Server exited with non-zero status: %d\n", $status['exitcode']);
                printf("Server output:\n%s\n", file_get_contents($output_file));
            }
            @unlink(__DIR__ . "/{$router}");
            remove_directory($doc_root);
        },
        $handle
    );
'@
    $newShutdown = ConvertTo-Lf -Text @'
    register_shutdown_function(
        function($handle, $debug_handle) use($router, $doc_root, $output_file) {
            proc_terminate($handle);
            $status = proc_get_status($handle);
            if ($status['exitcode'] !== -1 && $status['exitcode'] !== 0
                    && !($status['exitcode'] === 255 && PHP_OS_FAMILY == 'Windows')) {
                printf("Server exited with non-zero status: %d\n", $status['exitcode']);
                printf("Server output:\n%s\n", file_get_contents($output_file));
            }
            if (is_resource($debug_handle)) {
                @proc_terminate($debug_handle);
            }
            @unlink(__DIR__ . "/{$router}");
            remove_directory($doc_root);
        },
        $handle,
        $debug_handle
    );
'@
    if (-not $content.Contains($oldShutdown)) {
        throw "Unable to patch register_shutdown_function() block in $Path"
    }
    $content = $content.Replace($oldShutdown, $newShutdown)

    Set-Content -Path $Path -Value (Restore-Newlines -Text $content -Newline $newline) -NoNewline
    Write-Host "Patched CLI server helper for live ProcDump capture: $Path"
}

function Set-RunTestsWorkerDumpCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $DumpDir,
        [Parameter(Mandatory = $true)]
        [string] $ProcDumpExe,
        [Parameter(Mandatory = $true)]
        [string] $DebugLogPath
    )

    $rawContent = Get-Content -Path $Path -Raw
    $newline = if ($rawContent.Contains("`r`n")) { "`r`n" } else { "`n" }
    $content = ConvertTo-Lf -Text $rawContent
    if ($content -match 'buildphp_worker_recovery_attach_procdump') {
        Write-Host "Worker ProcDump patch already present in $Path"
        return
    }

    $phpProcDumpPath = ConvertTo-PhpSingleQuotedLiteral -Text $ProcDumpExe
    $phpDumpDir = ConvertTo-PhpSingleQuotedLiteral -Text $DumpDir
    $phpDebugLogPath = ConvertTo-PhpSingleQuotedLiteral -Text $DebugLogPath

    $helper = ConvertTo-Lf -Text @'
    function buildphp_worker_recovery_attach_procdump($proc)
    {
        if (PHP_OS_FAMILY !== 'Windows') {
            return;
        }

        $procdump = __WORKER_PROCDUMP_PATH__;
        $dumpDir = __WORKER_DUMP_DIR__;
        $logPath = __WORKER_PROCDUMP_LOG__;
        if (!$procdump || !is_file($procdump)) {
            @file_put_contents($logPath, date('c') . " skip missing ProcDump" . PHP_EOL, FILE_APPEND);
            return;
        }

        if (!is_dir($dumpDir) && !@mkdir($dumpDir, 0777, true) && !is_dir($dumpDir)) {
            @file_put_contents($logPath, date('c') . " skip missing dump dir " . $dumpDir . PHP_EOL, FILE_APPEND);
            return;
        }

        $status = @proc_get_status($proc);
        $pid = is_array($status) && isset($status['pid']) ? (int) $status['pid'] : 0;
        if ($pid <= 0) {
            @file_put_contents($logPath, date('c') . " skip missing worker pid" . PHP_EOL, FILE_APPEND);
            return;
        }

        $descriptorspec = [
            0 => ['file', 'NUL', 'r'],
            1 => ['file', 'NUL', 'a'],
            2 => ['file', 'NUL', 'a'],
        ];

        $attach = @proc_open(
            [
                $procdump,
                '-accepteula',
                '-e',
                '1',
                '-ma',
                '-x',
                $dumpDir,
                (string) $pid,
            ],
            $descriptorspec,
            $pipes,
            null,
            null,
            [
                "suppress_errors" => true,
                'create_new_console' => true,
            ]
        );

        @file_put_contents(
            $logPath,
            date('c') . " attach worker pid=" . $pid . " handle=" . (is_resource($attach) ? 'resource' : 'null') . PHP_EOL,
            FILE_APPEND
        );
    }

'@
    $helper = $helper.Replace('__WORKER_PROCDUMP_PATH__', $phpProcDumpPath)
    $helper = $helper.Replace('__WORKER_DUMP_DIR__', $phpDumpDir)
    $helper = $helper.Replace('__WORKER_PROCDUMP_LOG__', $phpDebugLogPath)

    $startWorkerMarker = '    function buildphp_worker_recovery_start_worker('
    if (-not $content.Contains($startWorkerMarker)) {
        throw "Unable to locate buildphp_worker_recovery_start_worker() in $Path"
    }
    $content = $content.Replace($startWorkerMarker, $helper + $startWorkerMarker)

    $oldRegister = ConvertTo-Lf -Text @'
        $workerProcs[$workerID] = $proc;
        $workerSocks[$workerID] = $workerSock;

        return true;
'@
    $newRegister = ConvertTo-Lf -Text @'
        $workerProcs[$workerID] = $proc;
        $workerSocks[$workerID] = $workerSock;
        buildphp_worker_recovery_attach_procdump($proc);

        return true;
'@
    if (-not $content.Contains($oldRegister)) {
        throw "Unable to patch worker registration block in $Path"
    }
    $content = $content.Replace($oldRegister, $newRegister)

    Set-Content -Path $Path -Value (Restore-Newlines -Text $content -Newline $newline) -NoNewline
    Write-Host "Patched run-tests worker spawn for ProcDump capture: $Path"
}

function Get-TestRunParams {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,
        [Parameter(Mandatory = $true)]
        [string] $TestListFile,
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    $timeout = if ($TestType -eq 'ext') { '300' } else { '120' }
    $params = @(
        '-n',
        '-d', 'open_basedir=',
        '-d', 'output_buffering=0',
        $Settings.runner,
        '-p', (Join-Path $Root 'phpbin\php.exe'),
        '-n',
        '-c', (Join-Path $Root 'phpbin\php.ini'),
        $Settings.progress,
        '-g', 'FAIL,BORK,WARN,LEAK',
        '-q',
        '--offline',
        '--show-diff',
        '--show-slow', '1000',
        '--set-timeout', $timeout,
        '--temp-source', (Join-Path $Root 'tests_tmp'),
        '--temp-target', (Join-Path $Root 'tests_tmp'),
        '-r', $TestListFile
    )
    if ($Settings.workers) {
        $params += $Settings.workers
    }
    return ,$params
}

function Reset-TestEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,
        [Parameter(Mandatory = $true)]
        [string] $DumpDir
    )

    Set-Variable -Name Arch -Value $Arch -Scope Global
    Remove-Item (Join-Path $Root 'file_cache') -Recurse -Force -ErrorAction Ignore
    Set-PhpIniForTests -BuildDirectory $Root -Opcache $Opcache -TestType $TestType

    $env:Path = (Join-Path $Root 'phpbin') + ';' + (Join-Path $env:DEPS_DIR 'bin') + ';' + $env:Path
    $env:TEST_PHP_EXECUTABLE = Join-Path $Root 'phpbin\php.exe'
    $env:TEST_PHPDBG_EXECUTABLE = Join-Path $Root 'phpbin\phpdbg.exe'
    $env:SKIP_IO_CAPTURE_TESTS = '1'
    $env:NO_INTERACTION = '1'
    $env:REPORT_EXIT_STATUS = '1'
}

function Initialize-CliServerExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $sourceExe = Join-Path $Root 'phpbin\php.exe'
    $targetExe = Join-Path $Root 'phpbin\php-cli-server.exe'
    if (-not (Test-Path $sourceExe)) {
        throw "CLI server source executable not found: $sourceExe"
    }

    Copy-Item -Path $sourceExe -Destination $targetExe -Force
    Write-Host "Prepared dedicated CLI server executable: $targetExe"
}

function Enable-SilentProcessExitDumpCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ImageName,
        [Parameter(Mandatory = $true)]
        [string] $DumpDir
    )

    if (-not $IsWindows) {
        Write-Warning 'Silent Process Exit dump capture is only available on Windows.'
        return $false
    }

    New-Item -Path $DumpDir -ItemType Directory -Force | Out-Null

    $ifeo = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ImageName"
    $spe = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SilentProcessExit\$ImageName"

    New-Item -Path $ifeo -Force | Out-Null
    New-Item -Path $spe -Force | Out-Null
    New-ItemProperty -Path $ifeo -Name GlobalFlag -Value 0x200 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $spe -Name ReportingMode -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $spe -Name DumpType -Value 2 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $spe -Name LocalDumpFolder -Value $DumpDir -PropertyType ExpandString -Force | Out-Null

    Write-Host "Enabled Silent Process Exit dumps for $ImageName in $DumpDir"
    return $true
}

function Disable-SilentProcessExitDumpCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ImageName
    )

    if (-not $IsWindows) {
        return
    }

    $ifeo = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ImageName"
    $spe = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SilentProcessExit\$ImageName"
    Remove-Item -Path $ifeo -Recurse -Force -ErrorAction Ignore
    Remove-Item -Path $spe -Recurse -Force -ErrorAction Ignore
    Write-Host "Disabled Silent Process Exit dumps for $ImageName"
}

function Stop-ReproProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $phpBin = (Join-Path $Root 'phpbin').ToLowerInvariant()
    $processNames = @('php.exe', 'php-cli-server.exe', 'php-cgi.exe', 'phpdbg.exe', 'procdump.exe', 'procdump64.exe')
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Ignore | Where-Object { $processNames -contains $_.Name })

    foreach ($process in $processes) {
        $shouldStop = $false
        if ($process.Name -like 'procdump*.exe') {
            $shouldStop = $true
        } elseif ($process.ExecutablePath) {
            $shouldStop = $process.ExecutablePath.ToLowerInvariant().StartsWith($phpBin)
        }

        if ($shouldStop) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Ignore
        }
    }

    Start-Sleep -Milliseconds 300
    Remove-Item (Join-Path $Root 'tests\run-test-info.php') -Force -ErrorAction Ignore
}

function Invoke-TestBatch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Root,
        [Parameter(Mandatory = $true)]
        [string] $DumpDir,
        [Parameter(Mandatory = $true)]
        [object] $Settings,
        [Parameter(Mandatory = $true)]
        [int] $Iterations,
        [Parameter(Mandatory = $false)]
        [string[]] $TestDirectories = @()
    )

    Set-Location (Join-Path $Root 'tests')
    for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
        Stop-ReproProcesses -Root $Root
        Reset-TestEnvironment -Root $Root -DumpDir $DumpDir
        Remove-Item (Join-Path $DumpDir '*') -Force -Recurse -ErrorAction Ignore

        $testListFile = "$Name-tests-to-run.txt"
        Get-TestsList -OutputFile $testListFile -Type $TestType -TestDirectories $TestDirectories

        $logFile = Join-Path $OutputDir ("$Name-{0:D3}.log" -f $iteration)
        if (Test-Path $logFile) {
            Remove-Item $logFile -Force
        }

        $env:TEST_PHP_JUNIT = Join-Path $OutputDir ("$Name-{0:D3}.xml" -f $iteration)
        $params = Get-TestRunParams -Root $Root -TestListFile $testListFile -Settings $Settings

        Write-Section "$Name iteration $iteration"
        try {
            & (Join-Path $Root 'phpbin\php.exe') @params 2>&1 | Tee-Object -FilePath $logFile | Out-Host
            $exitCode = $LASTEXITCODE
        } finally {
            Stop-ReproProcesses -Root $Root
        }

        $dumps = @(Get-ChildItem $DumpDir -Filter '*.dmp' -File -Recurse -ErrorAction Ignore | Sort-Object LastWriteTime -Descending)
        $crashObserved = (Test-Path -Path $logFile -PathType Leaf) -and (
            Select-String -Path $logFile -SimpleMatch -Quiet -Pattern @(
                'Server failed to start',
                'exitcode: -1073741819',
                '0xC0000005'
            )
        )
        if ($dumps.Count -gt 0 -and $crashObserved) {
            return [PSCustomObject]@{
                Captured = $true
                Dumps = $dumps
                LogFile = $logFile
                ExitCode = $exitCode
                Batch = $Name
                Iteration = $iteration
            }
        } elseif ($dumps.Count -gt 0) {
            Write-Host "Discarding $($dumps.Count) dump(s) from $Name iteration $iteration because no CLI crash marker was logged."
            $dumps | Remove-Item -Force -ErrorAction Ignore
        }
    }

    return [PSCustomObject]@{
        Captured = $false
        Dumps = @()
        LogFile = $null
        ExitCode = 0
        Batch = $Name
        Iteration = $Iterations
    }
}

function Analyze-Dumps {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]] $Dumps,
        [Parameter(Mandatory = $true)]
        [string] $StackDir
    )

    if ([string]::IsNullOrWhiteSpace($CdbPath) -or -not (Test-Path $CdbPath)) {
        Write-Warning 'cdb.exe not found. Skipping dump analysis.'
        return @()
    }

    $debugPack = Get-PhpDebugPackPath
    $symbolRoot = Join-Path $OutputDir 'symbols'
    Remove-Item $symbolRoot -Recurse -Force -ErrorAction Ignore
    if (Test-Path $debugPack) {
        Expand-Archive -Path $debugPack -DestinationPath $symbolRoot -Force
    } else {
        Write-Warning "Debug pack not found: $debugPack"
    }

    $symbolPaths = New-Object System.Collections.Generic.List[string]
    if (Test-Path $symbolRoot) {
        Get-ChildItem -Path $symbolRoot -Filter '*.pdb' -File -Recurse -ErrorAction Ignore |
            Select-Object -ExpandProperty DirectoryName -Unique |
            ForEach-Object { $symbolPaths.Add($_) }
    }
    $symbolPaths.Add("srv*$(Join-Path $OutputDir 'symcache')*https://msdl.microsoft.com/download/symbols")
    $searchPath = ($symbolPaths | Select-Object -Unique) -join ';'

    $stackFiles = @()
    foreach ($dump in $Dumps) {
        $stackFile = Join-Path $StackDir ($dump.BaseName + '.stack.txt')
        $analysis = & $CdbPath -z $dump.FullName -y $searchPath -c '!analyze -v; .ecxr; kpn; q' 2>&1 | Out-String -Width 300
        Set-Content -Path $stackFile -Value $analysis
        $stackFiles += $stackFile
    }
    return ,$stackFiles
}

Write-Section 'Validating inputs'
if (-not (Test-Path $BuilderRepoPath)) {
    throw "Builder repo path not found: $BuilderRepoPath"
}
if (-not (Test-Path $ArtifactsDir)) {
    throw "Artifacts directory not found: $ArtifactsDir"
}
if (-not (Test-Path $ProcDumpPath)) {
    throw "ProcDump was not found: $ProcDumpPath"
}

$repoRoot = $PWD.Path
$reproRoot = Join-Path $repoRoot 'repro-worktree'
$dumpDir = Join-Path $OutputDir 'dumps'
$stackDir = Join-Path $OutputDir 'stacks'

Remove-Item $OutputDir -Recurse -Force -ErrorAction Ignore
Remove-Item $reproRoot -Recurse -Force -ErrorAction Ignore
New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
New-Item -Path $dumpDir -ItemType Directory -Force | Out-Null
New-Item -Path $stackDir -ItemType Directory -Force | Out-Null
New-Item -Path $reproRoot -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $reproRoot 'tests_tmp') -ItemType Directory -Force | Out-Null

$env:DEPS_DIR = Join-Path $reproRoot 'deps'
$env:DEPS_CACHE_HIT = 'false'

Write-Section 'Importing builder module'
Import-Module (Join-Path $BuilderRepoPath 'php\BuildPhp') -Force

Write-Section 'Preparing artifact-backed test tree'
Set-Location $reproRoot
$setup = Add-TestRequirements `
    -PhpVersion $PhpVersion `
    -Arch $Arch `
    -Ts $Ts `
    -VsVersion 'vs18' `
    -TestsDirectory 'tests' `
    -ArtifactsDirectory $ArtifactsDir `
    -SourceRepository $SourceRepository `
    -SourceRef $SourceRef
$setup | Format-List | Out-Host

Initialize-CliServerExecutable -Root $reproRoot

$cliServerHelper = Join-Path $reproRoot 'tests\sapi\cli\tests\php_cli_server.inc'
Set-CliServerDumpCapture `
    -Path $cliServerHelper `
    -DumpDir $dumpDir `
    -ProcDumpExe $ProcDumpPath `
    -DebugFilter 'bug67198,php_cli_server_017,php_cli_server_019,bug65066_422,bug67429_1,ghsa-4w77-75f9-2c8w' `
    -DebugLogPath (Join-Path $OutputDir 'cli-server-debug.log')

Write-Section 'Preparing run settings'
$settings = Get-TestSettings -PhpVersion $PhpVersion
$fullResult = $null
$targetedResult = $null
$silentExitImageName = 'php-cli-server.exe'
$silentExitEnabled = $false

try {
    try {
        $silentExitEnabled = Enable-SilentProcessExitDumpCapture -ImageName $silentExitImageName -DumpDir $dumpDir
    } catch {
        Write-Warning "Unable to enable Silent Process Exit dumps for $silentExitImageName`: $_"
    }

    if ($RunFullSuite) {
        $fullResult = Invoke-TestBatch -Name 'full-suite' -Root $reproRoot -DumpDir $dumpDir -Settings $settings -Iterations 1
    }

    if (($null -eq $fullResult -or -not $fullResult.Captured) -and $StressIterations -gt 0) {
        $targetedTests = @(
            'tests\basic\bug67198.phpt',
            'sapi\cli\tests\php_cli_server_017.phpt',
            'sapi\cli\tests\php_cli_server_019.phpt',
            'sapi\cli\tests\bug65066_422.phpt',
            'sapi\cli\tests\bug67429_1.phpt',
            'sapi\cli\tests\ghsa-4w77-75f9-2c8w.phpt'
        )
        $targetedResult = Invoke-TestBatch -Name 'targeted-loop' -Root $reproRoot -DumpDir $dumpDir -Settings $settings -Iterations $StressIterations -TestDirectories $targetedTests
    }

    $capturedResult = @($fullResult, $targetedResult) | Where-Object { $null -ne $_ -and $_.Captured } | Select-Object -First 1
    $stackFiles = @()
    if ($null -ne $capturedResult) {
        Write-Section 'Analyzing dumps'
        $stackFiles = Analyze-Dumps -Dumps $capturedResult.Dumps -StackDir $stackDir
    }
} finally {
    if ($silentExitEnabled) {
        Disable-SilentProcessExitDumpCapture -ImageName $silentExitImageName
    }
}

$summaryFile = Join-Path $OutputDir 'summary.md'
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('# VS18 CLI Server Dump Repro')
$summary.Add('')
$summary.Add("- PHP version: $PhpVersion")
$summary.Add("- Architecture: $Arch")
$summary.Add("- TS: $Ts")
$summary.Add("- Opcache: $Opcache")
$summary.Add("- Test type: $TestType")
$summary.Add("- Source tests: $SourceRepository@$SourceRef")
$summary.Add("- Build artifacts: $ArtifactsDir")
$summary.Add("- Baseline results: $ResultsDir")
$summary.Add("- Full suite attempted: $RunFullSuite")
$summary.Add("- Targeted stress iterations: $StressIterations")
$summary.Add('')
if ($null -ne $capturedResult) {
    $summary.Add("- Dump captured: true")
    $summary.Add("- Capture batch: $($capturedResult.Batch)")
    $summary.Add("- Capture iteration: $($capturedResult.Iteration)")
    foreach ($dump in $capturedResult.Dumps) {
        $summary.Add("- Dump: $($dump.FullName)")
    }
    foreach ($stackFile in $stackFiles) {
        $summary.Add("- Stack: $stackFile")
    }
} else {
    $summary.Add("- Dump captured: false")
}
Set-Content -Path $summaryFile -Value ($summary -join [Environment]::NewLine)

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("dump_found={0}" -f (($null -ne $capturedResult).ToString().ToLowerInvariant()))
    Add-Content -Path $env:GITHUB_OUTPUT -Value ("summary_path={0}" -f $summaryFile)
}

Set-Location $repoRoot
Write-Section 'Summary'
Get-Content $summaryFile | Out-Host
$global:LASTEXITCODE = 0
