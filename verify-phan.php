<?php
$path = null;
foreach (explode(PATH_SEPARATOR, getenv('PATH')) as $directory) {
    $candidate = $directory . DIRECTORY_SEPARATOR . 'phan';
    if (is_file($candidate)) {
        $path = $candidate;
        break;
    }
}
if ($path === null) {
    throw new RuntimeException('Installed phan was not found');
}
$sha256 = hash_file('sha256', $path);
if ($sha256 !== '4cb9d8e6cd6848558eb1938802377a78e39d6840902520d43357e53cbd1ee794') {
    throw new RuntimeException('Installed asset does not match Phan 6.0.8: ' . $sha256);
}
$pharPath = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'setup-php-phan.phar';
copy($path, $pharPath);
$phar = new Phar($pharPath);
if (count($phar) === 0 || $phar->getSignature() === false) {
    throw new RuntimeException('Installed PHAR is empty or has no signature');
}
printf("Verified Phan 6.0.8: %d files; SHA256 %s\n", count($phar), $sha256);
