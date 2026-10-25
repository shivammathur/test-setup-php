$ErrorActionPreference = 'Stop'

$report = Join-Path $env:GITHUB_WORKSPACE 'report'
New-Item -ItemType Directory -Path $report -Force | Out-Null
$results = Join-Path $report 'results.txt'
$version = (& php -r 'echo PHP_VERSION;').Trim()
$defaultCleanup = (& php -r 'echo ini_get("session.upload_progress.cleanup");').Trim()
"PHP_VERSION=$version`nDEFAULT_CLEANUP=$defaultCleanup" | Set-Content $results
if ($defaultCleanup -ne '1') {
    throw "Expected PHP's default session.upload_progress.cleanup=1, got $defaultCleanup"
}

$upload = Join-Path $report 'upload.bin'
[IO.File]::WriteAllBytes($upload, [byte[]]::new(65536))

foreach ($cleanup in @(1, 0)) {
    $case = Join-Path $report "cleanup-$cleanup"
    $docroot = Join-Path $case 'docroot'
    $sessions = Join-Path $case 'sessions'
    New-Item -ItemType Directory -Path $docroot, $sessions -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $docroot 'index.php'), '')
    $target = Join-Path $docroot 'empty.php'
    [IO.File]::WriteAllText($target, '')
    $sid = "ci${cleanup}abcdefghijklmnopqrstuvwx"
    $sessionFile = Join-Path $sessions "sess_$sid"
    New-Item -ItemType HardLink -Path $sessionFile -Target $target | Out-Null

    $port = 18250 + $cleanup
    $url = "http://127.0.0.1:$port/index.php"
    $php = (Get-Command php).Source
    $process = Start-Process -FilePath $php -ArgumentList @(
        '-d', "session.save_path=$sessions",
        '-d', 'session.save_handler=files',
        '-d', 'session.serialize_handler=php',
        '-d', 'session.upload_progress.enabled=1',
        '-d', "session.upload_progress.cleanup=$cleanup",
        '-S', "127.0.0.1:$port", '-t', $docroot
    ) -RedirectStandardOutput (Join-Path $case 'server.out') `
      -RedirectStandardError (Join-Path $case 'server.err') -PassThru

    $client = [System.Net.Http.HttpClient]::new()
    try {
        $ready = $false
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            try {
                $response = $client.GetAsync($url).GetAwaiter().GetResult()
                $ready = $response.IsSuccessStatusCode
                $response.Dispose()
                if ($ready) { break }
            } catch {
                Start-Sleep -Milliseconds 200
            }
        }
        if (-not $ready) { throw "PHP server did not start for cleanup=$cleanup" }

        $client.DefaultRequestHeaders.Add('Cookie', "PHPSESSID=$sid")
        $form = [System.Net.Http.MultipartFormDataContent]::new()
        $form.Add([System.Net.Http.StringContent]::new('MARKER'), 'PHP_SESSION_UPLOAD_PROGRESS')
        $file = [System.Net.Http.ByteArrayContent]::new([IO.File]::ReadAllBytes($upload))
        $form.Add($file, 'upload', 'upload.bin')
        $response = $client.PostAsync($url, $form).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        $response.Dispose()
        $form.Dispose()
        if ($status -ne 200) { throw "Upload returned HTTP $status for cleanup=$cleanup" }

        $content = [IO.File]::ReadAllText($target)
        [IO.File]::WriteAllText((Join-Path $case 'target.txt'), $content)
        $marker = $content.Contains('upload_progress_MARKER|')
        "cleanup=$cleanup status=$status target_bytes=$([Text.Encoding]::UTF8.GetByteCount($content)) marker=$marker" |
            Add-Content $results
        if ($cleanup -eq 0 -and -not $marker) {
            throw 'Hardlinked target did not retain the benign upload-progress marker'
        }
        if ($cleanup -eq 1 -and $content.Length -ne 0) {
            throw 'Hardlinked target was not restored with default cleanup'
        }
    } finally {
        $client.Dispose()
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
}

Get-Content $results
