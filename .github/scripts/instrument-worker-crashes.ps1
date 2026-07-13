param(
    [Parameter(Mandatory)]
    [string] $PatchPath
)

$content = [System.IO.File]::ReadAllText($PatchPath).Replace("`r`n", "`n")

function Replace-Required {
    param(
        [Parameter(Mandatory)]
        [string] $Needle,
        [Parameter(Mandatory)]
        [string] $Replacement
    )

    $Needle = $Needle.Replace("`r`n", "`n")
    $Replacement = $Replacement.Replace("`r`n", "`n")

    if (-not $script:content.Contains($Needle)) {
        throw "Instrumentation target was not found in $PatchPath"
    }

    $script:content = $script:content.Replace($Needle, $Replacement)
}

$deathNeedle = @'
+        $hadBatch = isset($workerBatches[$workerID]);
+        if ($hadBatch) {
'@
$deathReplacement = @'
+        $hadBatch = isset($workerBatches[$workerID]);
+        $workerStatus = isset($workerProcs[$workerID]) ? proc_get_status($workerProcs[$workerID]) : null;
+        $crashedTest = $hadBatch ? $workerBatches[$workerID]['current'] : null;
+        $exitCode = $workerStatus === null ? 'unknown' : (string) $workerStatus['exitcode'];
+        $running = $workerStatus === null ? 'unknown' : ($workerStatus['running'] ? 'true' : 'false');
+        echo "WORKER_CRASH worker=$workerID exit=$exitCode running=$running";
+        if ($crashedTest !== null) {
+            echo " test=" . buildphp_worker_recovery_test_file($crashedTest['assigned_name']);
+        }
+        echo "\n";
+        if ($hadBatch) {
'@
Replace-Required -Needle $deathNeedle -Replacement $deathReplacement

$retryNeedle = @'
+    if ($workerCrashRetryTests) {
+        echo "Retrying " . count($workerCrashRetryTests) . " tests interrupted by worker crashes serially...\n";
+        $savedWorkers = $workers;
+        $workers = null;
+        run_all_tests($workerCrashRetryTests, $env, $redir_tested);
+        $workers = $savedWorkers;
+    }
'@
$retryReplacement = @'
+    if ($workerCrashRetryTests) {
+        echo "Retrying " . count($workerCrashRetryTests) . " tests interrupted by worker crashes serially...\n";
+        foreach ($workerCrashRetryTests as $retryTest) {
+            echo "WORKER_CRASH_RETRY_TEST " . buildphp_worker_recovery_test_file($retryTest) . "\n";
+        }
+        $savedWorkers = $workers;
+        $workers = null;
+        foreach ($workerCrashRetryTests as $retryTest) {
+            echo "WORKER_CRASH_SERIAL_TEST " . buildphp_worker_recovery_test_file($retryTest) . "\n";
+            run_all_tests([$retryTest], $env, $redir_tested);
+        }
+        $workers = $savedWorkers;
+    }
'@
Replace-Required -Needle $retryNeedle -Replacement $retryReplacement
Replace-Required `
    -Needle '@@ -140,6 +140,292 @@' `
    -Replacement '@@ -140,6 +140,301 @@'
Replace-Required `
    -Needle '@@ -1631,3 +1941,11 @@' `
    -Replacement '@@ -1631,3 +1941,17 @@'

[System.IO.File]::WriteAllText(
    $PatchPath,
    $content,
    [System.Text.UTF8Encoding]::new($false)
)
