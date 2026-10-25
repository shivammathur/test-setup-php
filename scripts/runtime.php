<?php
function check($condition, $message) {
    if (!$condition) {
        throw new Exception($message);
    }
}
$versions = array('5.3' => '5.3.29', '5.4' => '5.4.45', '5.5' => '5.5.38');
check(PHP_VERSION === $versions[getenv('PHP_MINOR')], 'Unexpected PHP version');
check(ini_get('memory_limit') === '256M', 'setup-php ini override missing');
check(ini_get('date.timezone') === 'UTC', 'setup-php timezone override missing');
foreach (array('curl', 'dom', 'gd', 'iconv', 'intl', 'mbstring', 'mysqli', 'openssl', 'pdo_mysql', 'pdo_sqlite', 'soap', 'sockets', 'sqlite3', 'xml', 'zip', 'imagick') as $extension) {
    check(extension_loaded($extension), 'Missing extension: ' . $extension);
}
check(mb_strlen('é', 'UTF-8') === 1, 'mbstring failed');
$xml = new DOMDocument();
check($xml->loadXML('<root><value>ok</value></root>'), 'DOM failed');
check($xml->getElementsByTagName('value')->item(0)->nodeValue === 'ok', 'DOM value mismatch');
$database = new PDO('sqlite::memory:');
check((int) $database->query('SELECT 2 + 3')->fetchColumn() === 5, 'PDO SQLite failed');
$database = new SQLite3(':memory:');
check($database->querySingle('SELECT 2 + 3') === 5, 'SQLite3 failed');
$formatter = new NumberFormatter('en_US', NumberFormatter::DECIMAL);
check($formatter->format(1234.5) === '1,234.5', 'Intl formatting failed');
$image = imagecreatetruecolor(2, 2);
check($image !== false, 'GD failed');
imagedestroy($image);
$image = new Imagick();
$image->newImage(2, 2, 'white');
check($image->getImageWidth() === 2, 'Imagick failed');
$path = tempnam(sys_get_temp_dir(), 'setup-php-zip-');
unlink($path);
$zip = new ZipArchive();
check($zip->open($path, ZipArchive::CREATE) === true, 'ZIP create failed');
check($zip->addFromString('check.txt', 'ok') && $zip->close(), 'ZIP write failed');
check($zip->open($path) === true && $zip->getFromName('check.txt') === 'ok', 'ZIP read failed');
$zip->close();
unlink($path);
$curl = curl_init('https://repo.packagist.org/packages.json');
curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
curl_setopt($curl, CURLOPT_TIMEOUT, 30);
$body = curl_exec($curl);
check($body !== false && curl_getinfo($curl, CURLINFO_HTTP_CODE) === 200, 'HTTPS curl failed: ' . curl_error($curl));
curl_close($curl);
check(file_get_contents('https://repo.packagist.org/packages.json') !== false, 'HTTPS stream failed');
echo json_encode(array('php' => PHP_VERSION, 'curl' => curl_version(), 'extensions' => get_loaded_extensions())), "\n";
