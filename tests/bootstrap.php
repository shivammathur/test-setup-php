<?php

$_tests_dir = getenv('WP_TESTS_DIR');

if (! $_tests_dir) {
    $_tests_dir = rtrim(sys_get_temp_dir(), '/\\') . '/wordpress-tests-lib';
}

$_phpunit_polyfills_path = getenv('WP_TESTS_PHPUNIT_POLYFILLS_PATH');
if (false !== $_phpunit_polyfills_path) {
    define('WP_TESTS_PHPUNIT_POLYFILLS_PATH', $_phpunit_polyfills_path);
}

if (! file_exists("{$_tests_dir}/includes/functions.php")) {
    echo "Could not find {$_tests_dir}/includes/functions.php, have you run bin/install-wp-tests.sh ?\n";
    exit(1);
}

require_once "{$_tests_dir}/includes/functions.php";

function _manually_load_plugin(): void
{
    require dirname(__DIR__) . '/sample-plugin.php';
}

tests_add_filter('muplugins_loaded', '_manually_load_plugin');

require "{$_tests_dir}/includes/bootstrap.php";
