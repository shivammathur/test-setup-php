<?php
if (!imagecreatetruecolor(2, 2)) { throw new Exception('GD failed'); }
if (gmp_strval(gmp_add('2', '3')) !== '5') { throw new Exception('GMP failed'); }
$db = new SQLite3(':memory:');
if ($db->querySingle('SELECT 2 + 3') !== 5) { throw new Exception('SQLite failed'); }
$file = tempnam(sys_get_temp_dir(), 'zip'); unlink($file);
$zip = new ZipArchive();
if ($zip->open($file, ZipArchive::CREATE) !== true || !$zip->addFromString('test', 'ok') || !$zip->close()) { throw new Exception('ZIP failed'); }
unlink($file);
$curl = curl_init('https://repo.packagist.org/packages.json');
curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
if (curl_exec($curl) === false || curl_getinfo($curl, CURLINFO_HTTP_CODE) !== 200) { throw new Exception(curl_error($curl)); }
if (file_get_contents('https://repo.packagist.org/packages.json') === false) { throw new Exception('HTTPS stream failed'); }
$xml = new DOMDocument(); $xml->loadXML('<root/>');
$style = new DOMDocument();
$style->loadXML('<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:template match="/"><ok/></xsl:template></xsl:stylesheet>');
$xsl = new XSLTProcessor(); $xsl->importStylesheet($style);
if (strpos($xsl->transformToXML($xml), '<ok/>') === false) { throw new Exception('XSL failed'); }
echo "PHP runtime behavior checks passed\n";
