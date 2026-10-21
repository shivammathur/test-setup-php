<?php
$normal = get_loaded_extensions(false);
$zend = get_loaded_extensions(true);
sort($normal, SORT_STRING);
sort($zend, SORT_STRING);
$versions = array();
foreach (array_unique(array_merge($normal, $zend)) as $name) {
    $extension = new ReflectionExtension($name);
    $versions[$name] = $extension->getVersion();
}
echo json_encode(array('php_version' => PHP_VERSION, 'int_size' => PHP_INT_SIZE,
    'sapi' => PHP_SAPI, 'zts' => (bool) PHP_ZTS, 'debug' => (bool) PHP_DEBUG, 'normal_extensions' => $normal, 'zend_extensions' => $zend,
    'extension_versions' => $versions, 'loaded_ini' => php_ini_loaded_file(),
    'scanned_ini' => php_ini_scanned_files())) . "\n";
