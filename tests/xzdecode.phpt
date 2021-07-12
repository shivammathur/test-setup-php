--TEST--
Test `xzdecode` simple case
--SKIPIF--
<?php
if (!extension_loaded("xz")) {
	print("XZ extension is not loaded!");
}
?>
--FILE--
<?php

$str = file_get_contents(__FILE__);

$encoded = xzencode($str);
print("encoding finished\n");
$decoded = xzdecode($encoded);
print("decoding finished\n");
var_dump($str === $decoded);

print("empty string\n");
var_dump(xzdecode(""));
print("garbage\n");
var_dump(xzdecode("this is not XZ data"));
?>
--EXPECT--
encoding finished
decoding finished
bool(true)
empty string
bool(false)
garbage
bool(false)
