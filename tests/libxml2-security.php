<?php
declare(strict_types=1);

$results = [];
$selectedTest = $argv[1] ?? null;
$expectedLibxml = getenv('EXPECTED_LIBXML_VERSION') ?: '2.15.4';
$expectedVersionParts = array_map('intval', explode('.', $expectedLibxml));
if (count($expectedVersionParts) !== 3) {
    throw new RuntimeException("Invalid expected libxml2 version: {$expectedLibxml}");
}
$expectedLibxmlNumeric = $expectedVersionParts[0] * 10000 + $expectedVersionParts[1] * 100 + $expectedVersionParts[2];
function check(string $name, callable $test): void {
    global $results, $selectedTest;
    if ($selectedTest === '--list') {
        $results[] = $name;
        return;
    }
    if ($selectedTest !== null && $selectedTest !== $name) {
        return;
    }
    try {
        if ($test() !== true) {
            throw new RuntimeException('Unexpected result');
        }
        $results[] = ['name' => $name, 'status' => 'passed'];
    } catch (Throwable $error) {
        $results[] = ['name' => $name, 'status' => 'failed', 'error' => $error->getMessage()];
    }
}

libxml_use_internal_errors(true);
check('headers-and-runtime-version', fn() => LIBXML_VERSION === $expectedLibxmlNumeric && LIBXML_DOTTED_VERSION === $expectedLibxml && LIBXML_LOADED_VERSION === (string) $expectedLibxmlNumeric);
check('extensions', fn() => count(array_filter(['dom', 'libxml', 'SimpleXML', 'xml', 'xmlreader', 'xmlwriter', 'xsl'], 'extension_loaded')) === 7);
check('dom-xpath-namespaces', function () {
    $doc = new DOMDocument();
    $doc->loadXML('<r xmlns:a="urn:test"><a:item id="1">é</a:item></r>');
    $xpath = new DOMXPath($doc);
    $xpath->registerNamespace('a', 'urn:test');
    return $xpath->evaluate('string(/r/a:item[@id="1"])') === 'é';
});
check('modern-dom', function () {
    if (PHP_VERSION_ID < 80400) {
        return true;
    }
    $doc = Dom\XMLDocument::createFromString('<r><item>value</item></r>');
    return $doc->documentElement->firstElementChild->textContent === 'value';
});
check('html-output-encoding', function () {
    $doc = new DOMDocument('1.0', 'UTF-8');
    $doc->loadHTML('<html><body><p>hello</p></body></html>');
    return str_contains($doc->saveHTML(), '<p>hello</p>');
});
check('html-output-failure-ownership', function () {
    $doc = new DOMDocument();
    $doc->loadHTML('<html><body>encoding</body></html>');
    $doc->encoding = 'ISO-8859-1';
    for ($i = 0; $i < 25; $i++) {
        $result = @$doc->saveHTMLFile(__DIR__ . '/missing-directory/output.html');
        if ($result !== false && $result !== 0) {
            return false;
        }
    }
    return str_contains($doc->saveHTML(), 'encoding');
});
check('simplexml-roundtrip', function () {
    $xml = simplexml_load_string('<root><item id="1">value</item></root>');
    return (string) $xml->xpath('/root/item[@id="1"]')[0] === 'value';
});
check('xmlreader', function () {
    $reader = XMLReader::XML('<root><item>value</item></root>');
    $names = [];
    while ($reader->read()) {
        if ($reader->nodeType === XMLReader::ELEMENT) $names[] = $reader->name;
    }
    $reader->close();
    return $names === ['root', 'item'];
});
check('xmlwriter', function () {
    $writer = new XMLWriter();
    $writer->openMemory();
    $writer->startDocument('1.0', 'UTF-8');
    $writer->writeElement('root', 'é & value');
    $writer->endDocument();
    return (string) simplexml_load_string($writer->outputMemory()) === 'é & value';
});
check('sax', function () {
    $parser = xml_parser_create();
    $text = '';
    xml_set_character_data_handler($parser, function ($parser, $data) use (&$text) { $text .= $data; });
    return xml_parse($parser, '<root>value</root>', true) === 1 && $text === 'value';
});
check('canonicalization', function () {
    $doc = new DOMDocument();
    $doc->loadXML('<r b="2" a="1"><c/></r>');
    return $doc->C14N() === '<r a="1" b="2"><c></c></r>';
});
check('schema-validation', function () {
    $doc = new DOMDocument();
    $doc->loadXML('<root>42</root>');
    return $doc->schemaValidateSource('<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="root" type="xs:integer"/></xs:schema>');
});
check('relaxng-validation', function () {
    $doc = new DOMDocument();
    $doc->loadXML('<root>value</root>');
    return $doc->relaxNGValidateSource('<element xmlns="http://relaxng.org/ns/structure/1.0" name="root"><text/></element>');
});
check('invalid-dtd-large-content', function () {
    $doc = new DOMDocument();
    $doc->loadXML('<!DOCTYPE root [<!ELEMENT root (allowed)><!ELEMENT allowed EMPTY><!ELEMENT child EMPTY>]><root>' . str_repeat('<child/>', 5000) . '</root>');
    libxml_clear_errors();
    return !$doc->validate() && count(libxml_get_errors()) > 0;
});
check('xinclude-local-file', function () {
    $file = tempnam(sys_get_temp_dir(), 'libxml2-');
    file_put_contents($file, '<included>value</included>');
    try {
        $doc = new DOMDocument();
        $doc->loadXML('<root xmlns:xi="http://www.w3.org/2001/XInclude"><xi:include href="' . htmlspecialchars(str_replace('\\', '/', $file), ENT_XML1) . '"/></root>');
        return $doc->xinclude(LIBXML_NONET) === 1 && $doc->getElementsByTagName('included')->item(0)->textContent === 'value';
    } finally {
        unlink($file);
    }
});
check('xslt-transform', function () {
    $xml = new DOMDocument();
    $xml->loadXML('<root><item>one</item><item>two</item></root>');
    $xsl = new DOMDocument();
    $xsl->loadXML('<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:output method="text"/><xsl:template match="/"><xsl:for-each select="root/item"><xsl:value-of select="."/><xsl:text>;</xsl:text></xsl:for-each></xsl:template></xsl:stylesheet>');
    $proc = new XSLTProcessor();
    return $proc->importStylesheet($xsl) && $proc->transformToXML($xml) === 'one;two;';
});

if ($selectedTest === '--list') {
    echo json_encode($results), "\n";
    exit(0);
}
$report = ['php' => PHP_VERSION, 'expected_libxml' => $expectedLibxml, 'libxml_headers' => LIBXML_DOTTED_VERSION, 'libxml_runtime' => LIBXML_LOADED_VERSION, 'libxslt' => defined('LIBXSLT_DOTTED_VERSION') ? LIBXSLT_DOTTED_VERSION : null, 'tests' => $results];
echo json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
exit(count(array_filter($results, fn($test) => $test['status'] === 'failed')) > 0 ? 1 : 0);
