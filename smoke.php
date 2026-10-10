<?php
function check($condition, $message) {
    if (!$condition) { throw new RuntimeException($message); }
}
check(strpos(PHP_VERSION, getenv('PHP_VERSION') . '.') === 0, 'Wrong PHP version');
check(strpos(OPENSSL_VERSION_TEXT, 'OpenSSL 4.') === 0, 'Wrong OpenSSL headers');
ob_start(); phpinfo(INFO_MODULES); $info = ob_get_clean();
check(preg_match('/OpenSSL Library Version => OpenSSL 4\./', $info), 'Wrong OpenSSL runtime');
$data = 'php-darwin OpenSSL 4 validation';
$key = openssl_random_pseudo_bytes(32);
$iv = openssl_random_pseudo_bytes(16);
$cipher = openssl_encrypt($data, 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv);
check($cipher !== false && openssl_decrypt($cipher, 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv) === $data, 'AES roundtrip');
$private = openssl_pkey_new(array('private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA));
check($private !== false && openssl_sign($data, $signature, $private, OPENSSL_ALGO_SHA256), 'RSA signing');
$public = openssl_pkey_get_details($private);
check(openssl_verify($data, $signature, $public['key'], OPENSSL_ALGO_SHA256) === 1, 'RSA verification');
foreach (array('imagick', 'mongodb', 'memcached', 'igbinary', 'msgpack') as $module) {
    check(extension_loaded($module), 'Missing ' . $module);
}
$image = new Imagick(); $image->newImage(16, 16, 'white');
foreach (array('PNG', 'JPEG', 'WEBP') as $format) {
    $image->setImageFormat($format); check(strlen($image->getImageBlob()) > 10, 'Image codec ' . $format);
}
$bson = class_exists('MongoDB\\BSON\\Document')
    ? MongoDB\BSON\Document::fromPHP(array('cache' => 42))->toPHP()
    : MongoDB\BSON\toPHP(MongoDB\BSON\fromPHP(array('cache' => 42)));
check($bson->cache === 42, 'BSON roundtrip');
$memcached = new Memcached();
foreach (array(Memcached::SERIALIZER_PHP, Memcached::SERIALIZER_IGBINARY, Memcached::SERIALIZER_MSGPACK) as $serializer) {
    check($memcached->setOption(Memcached::OPT_SERIALIZER, $serializer), 'Memcached serializer');
}
if (version_compare(getenv('PHP_VERSION'), '8.6', '<')) {
    check(extension_loaded('swoole'), 'Missing Swoole');
    $table = new Swoole\Table(64); $table->column('value', Swoole\Table::TYPE_INT);
    check($table->create() && $table->set('test', array('value' => 42)) && $table->get('test')['value'] === 42, 'Swoole table');
    $table->destroy();
}
$url = getenv('TLS_URL'); $ca = getenv('TLS_CA');
$ctx = stream_context_create(array('ssl' => array('cafile' => $ca, 'verify_peer' => true, 'verify_peer_name' => true)));
check(strpos(file_get_contents($url, false, $ctx), 's_server') !== false, 'Verified PHP stream TLS');
check(strpos(curl_version()['ssl_version'], 'OpenSSL/4.') === 0, 'cURL OpenSSL version');
$curl = curl_init($url);
curl_setopt_array($curl, array(CURLOPT_RETURNTRANSFER => true, CURLOPT_CAINFO => $ca, CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2, CURLOPT_TIMEOUT => 15));
$response = curl_exec($curl);
check($response !== false && strpos($response, 's_server') !== false, 'Verified cURL TLS: ' . curl_error($curl));
echo PHP_VERSION, ': ', OPENSSL_VERSION_TEXT, "; AES/RSA, verified stream/cURL TLS, and optional extensions passed\n";
