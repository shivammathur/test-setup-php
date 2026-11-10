#!/usr/bin/env bash
set -euo pipefail
php -v
composer --version
php -r '
if (PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 5) { throw new Exception("Wrong PHP version"); }
foreach (["curl", "mbstring", "intl", "pdo_mysql", "gd", "xdebug"] as $extension) {
    if (!extension_loaded($extension)) { throw new Exception("Missing extension: $extension"); }
}
if (ini_get("post_max_size") !== "256M" || ini_get("date.timezone") !== "Asia/Kolkata") { throw new Exception("Incorrect ini configuration"); }
echo json_encode(["php" => PHP_VERSION, "extensions" => get_loaded_extensions(), "post_max_size" => ini_get("post_max_size"), "timezone" => ini_get("date.timezone")], JSON_PRETTY_PRINT), "\n";
'
