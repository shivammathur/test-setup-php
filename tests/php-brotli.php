<?php
declare(strict_types=1);
function verify(bool $condition, string $message): void {
    if (!$condition) { throw new RuntimeException($message); }
}
$version = curl_version();
verify($version['version'] === '8.23.0', 'Unexpected curl version');
verify(($version['brotli_version'] ?? '') === 'brotli/1.2.1' && ($version['brotli_ver_num'] ?? 0) === 0x01002001, 'Unexpected Brotli version: ' . json_encode($version));
verify(($version['features'] & CURL_VERSION_BROTLI) !== 0, 'Brotli support missing');
verify(in_array('smb', $version['protocols'], true) && in_array('smbs', $version['protocols'], true), 'SMB/SMBS changed');
$expected = file_get_contents($argv[2]);
$cases = 4;
foreach (['/valid', '/chunked', '/gzip', '/gzip-chunked', '/deflate'] as $path) {
    foreach (['return', 'callback'] as $mode) {
        $ch = curl_init($argv[1] . $path);
        $received = '';
        curl_setopt_array($ch, [CURLOPT_ENCODING => '', CURLOPT_TIMEOUT => 20, CURLOPT_NOPROXY => '*']);
        if ($mode === 'return') curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        else curl_setopt($ch, CURLOPT_WRITEFUNCTION, static function ($ch, string $chunk) use (&$received): int { $received .= $chunk; return strlen($chunk); });
        $result = curl_exec($ch);
        verify($result !== false, curl_error($ch));
        verify(($mode === 'return' ? $result : $received) === $expected, 'Decoded payload mismatch');
        unset($ch);
        $cases++;
    }
}
$ch=curl_init($argv[1] . '/invalid');
curl_setopt_array($ch,[CURLOPT_ENCODING=>'',CURLOPT_RETURNTRANSFER=>true,CURLOPT_TIMEOUT=>20,CURLOPT_NOPROXY=>'*']);
verify(curl_exec($ch)===false && curl_errno($ch)===CURLE_BAD_CONTENT_ENCODING,'Malformed Brotli must fail cleanly');
unset($ch); $cases++;
$multi=curl_multi_init();$handles=[];
for($i=0;$i<8;$i++) {
    $ch=curl_init($argv[1].($i%2?'/valid':'/chunked'));
    curl_setopt_array($ch,[CURLOPT_ENCODING=>'',CURLOPT_RETURNTRANSFER=>true,CURLOPT_TIMEOUT=>20,CURLOPT_NOPROXY=>'*']);
    curl_multi_add_handle($multi,$ch);$handles[]=$ch;
}
do { $status=curl_multi_exec($multi,$active);verify($status===CURLM_OK,'Multi operation failed');if($active) curl_multi_select($multi,0.1); } while($active);
foreach($handles as $ch) {verify(curl_errno($ch)===0 && curl_multi_getcontent($ch)===$expected,'Multi decode mismatch');curl_multi_remove_handle($multi,$ch);$cases++;}
echo json_encode(['php'=>PHP_VERSION,'curl'=>$version['version'],'brotli'=>$version['brotli_version'],'cases'=>$cases,'failures'=>0],JSON_PRETTY_PRINT),"\n";
