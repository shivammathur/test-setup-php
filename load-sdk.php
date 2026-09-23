<?php
$root = realpath($argv[1]) . '/lib/php/libsdk/';
set_error_handler(function ($severity, $message, $file, $line) {
    throw new ErrorException($message, 0, $severity, $file, $line);
});
spl_autoload_register(function ($name) use ($root) {
    $path = $root . str_replace('\\', '/', $name) . '.php';
    if (is_file($path)) require_once $path;
});
$count = 0;
foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS)) as $file) {
    if ($file->getExtension() !== 'php' || $file->getSize() === 0) continue;
    $name = str_replace(array('/', '\\'), '\\', substr($file->getPathname(), strlen($root), -4));
    if (!class_exists($name) && !interface_exists($name) && !trait_exists($name)) throw new RuntimeException($name);
    $count++;
}
echo "Loaded $count SDK types without diagnostics on PHP " . PHP_VERSION . "\n";
