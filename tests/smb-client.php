<?php
declare(strict_types=1);
$request = json_decode($argv[1], true, flags: JSON_THROW_ON_ERROR);
$ch = curl_init();
curl_setopt_array($ch, [
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 15,
    CURLOPT_USERPWD => 'curltest:' . $request['password'],
    CURLOPT_CAINFO => $request['ca'],
]);
$input = null;
if ($request['upload'] !== null) {
    $input = fopen($request['upload'], 'rb');
    curl_setopt_array($ch, [CURLOPT_UPLOAD => true, CURLOPT_INFILE => $input, CURLOPT_INFILESIZE => filesize($request['upload'])]);
}
$bodies = [];
$code = 0;
$error = '';
foreach ($request['urls'] as $url) {
    curl_setopt($ch, CURLOPT_URL, $url);
    $body = curl_exec($ch);
    $code = curl_errno($ch);
    $error = curl_error($ch);
    if ($body === false) { break; }
    $bodies[] = base64_encode($body);
}
echo json_encode(['code' => $code, 'error' => $error, 'bodies' => $bodies], JSON_THROW_ON_ERROR);
if (is_resource($input)) { fclose($input); }
