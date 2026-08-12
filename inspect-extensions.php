<?php

declare(strict_types=1);

$label = $argv[1] ?? 'unknown';
$extensions = [
    'curl',
    'date',
    'dom',
    'fileinfo',
    'filter',
    'iconv',
    'json',
    'libxml',
    'mbstring',
    'openssl',
    'phar',
    'session',
    'simplexml',
    'sockets',
    'tokenizer',
    'zip',
    'zlib',
];

$staticCommand = escapeshellarg(PHP_BINARY)
    .' -n -r '
    .escapeshellarg('echo json_encode(array_map("strtolower", get_loaded_extensions()));');
$staticExtensions = json_decode((string) shell_exec($staticCommand), true, 512, JSON_THROW_ON_ERROR);
$staticExtensions = array_fill_keys($staticExtensions, true);
$extensionDir = (string) ini_get('extension_dir');
$suffix = PHP_SHLIB_SUFFIX;

$results = [];
foreach ($extensions as $extension) {
    $moduleCandidates = [
        $extensionDir.DIRECTORY_SEPARATOR.$extension.'.'.$suffix,
        $extensionDir.DIRECTORY_SEPARATOR.'php_'.$extension.'.'.$suffix,
    ];
    $moduleFiles = array_values(array_filter($moduleCandidates, 'is_file'));
    $loaded = extension_loaded($extension);
    $static = isset($staticExtensions[strtolower($extension)]);

    if ($static) {
        $classification = 'static';
    } elseif ($loaded && $moduleFiles !== []) {
        $classification = 'shared-loaded';
    } elseif ($loaded) {
        $classification = 'loaded-without-matching-module-file';
    } elseif ($moduleFiles !== []) {
        $classification = 'shared-disabled';
    } else {
        $classification = 'unavailable';
    }

    $results[$extension] = [
        'loaded' => $loaded,
        'static' => $static,
        'module_files' => $moduleFiles,
        'classification' => $classification,
    ];
}

echo json_encode([
    'label' => $label,
    'os' => PHP_OS_FAMILY,
    'php_version' => PHP_VERSION,
    'php_binary' => PHP_BINARY,
    'loaded_ini' => php_ini_loaded_file(),
    'scanned_inis' => php_ini_scanned_files(),
    'extension_dir' => $extensionDir,
    'extensions' => $results,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), PHP_EOL;
