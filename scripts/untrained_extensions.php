<?php

$checksum = 0;

$xml = '<catalog>';
for ($i = 0; $i < 80; $i++) {
    $xml .= sprintf(
        '<item id="%d"><name>Package %d</name><score>%d</score></item>',
        $i,
        $i,
        ($i * 37) % 101,
    );
}
$xml .= '</catalog>';

for ($round = 0; $round < 1200; $round++) {
    $document = new DOMDocument();
    $document->loadXML($xml, LIBXML_NONET | LIBXML_COMPACT);
    $xpath = new DOMXPath($document);
    foreach ($xpath->query('//item[number(score) >= 50]/name') as $node) {
        $checksum += strlen($node->textContent);
    }
}

$collator = new Collator('en_US');
$formatter = new NumberFormatter('en_US', NumberFormatter::DECIMAL);
$values = ['Zulu 20', 'alpha 3', 'Éclair 11', 'Beta 1', 'ångström 7', 'delta 15'];
for ($round = 0; $round < 40000; $round++) {
    $sorted = $values;
    $collator->sort($sorted, Collator::SORT_STRING);
    $checksum += strlen(implode('|', $sorted));
    $checksum += strlen($formatter->format(($round * 7919) / 37));
}

$base = gmp_init('123456789012345678901234567890123456789');
$modulus = gmp_init('340282366920938463463374607431768211507');
for ($i = 1; $i <= 150000; $i++) {
    $result = gmp_powm($base, ($i % 251) + 1, $modulus);
    $checksum += strlen(gmp_strval($result));
}

for ($round = 0; $round < 120; $round++) {
    $image = imagecreatetruecolor(256, 256);
    for ($i = 0; $i < 24; $i++) {
        $color = imagecolorallocate($image, ($i * 17) % 256, ($i * 29) % 256, ($i * 43) % 256);
        imagefilledrectangle($image, $i * 3, $i * 2, 255 - $i * 2, 255 - $i * 3, $color);
    }
    imagefilter($image, IMG_FILTER_GAUSSIAN_BLUR);
    $scaled = imagescale($image, 128, 128, IMG_BILINEAR_FIXED);
    $checksum += imagecolorat($scaled, $round % 128, ($round * 7) % 128);
    unset($scaled, $image);
}

echo $checksum, PHP_EOL;
