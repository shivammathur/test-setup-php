<?php
declare(strict_types=1);
$files = [php_ini_loaded_file(), ...preg_split('/,\s*/', php_ini_scanned_files() ?: '')];
foreach (array_filter($files) as $file) {
    $content = file_get_contents(trim($file));
    $updated = preg_replace('/^[ \t]*(?:zend_)?extension\s*=.*phpstan_turbo.*(?:\R|$)/mi', '', $content);
    if ($updated === $content) {
        continue;
    }
    if (is_link(trim($file))) {
        if (!unlink(trim($file))) {
            throw new RuntimeException("Could not disable $file");
        }
        continue;
    }
    if (file_put_contents(trim($file), $updated) === false) {
        throw new RuntimeException("Could not update $file");
    }
}
$process = proc_open([PHP_BINARY, '-r', 'exit(extension_loaded("phpstan_turbo") ? 1 : 0);'], [0 => ['pipe', 'r'], 1 => STDOUT, 2 => STDERR], $pipes);
fclose($pipes[0]);
if (proc_close($process) !== 0) {
    throw new RuntimeException('Turbo is still loaded after removing activation');
}
echo "Turbo disabled; the PIE package and binary remain cached.\n";
