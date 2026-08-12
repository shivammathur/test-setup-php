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

    $results[$extension] = [
        'loaded' => $loaded,
        'module_files' => $moduleFiles,
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
