<?php

use pmmp\encoding\ByteBufferReader;
use pmmp\encoding\ByteBufferWriter;
use pmmp\encoding\VarInt;

if (PHP_MAJOR_VERSION !== 8 || PHP_MINOR_VERSION !== 5 || phpversion('encoding') !== '1.0.0') {
    throw new RuntimeException('Expected PHP 8.5 with encoding 1.0.0');
}

foreach ([0, 1, 127, 128, 300, 2147483647, 4294967295] as $value) {
    $writer = new ByteBufferWriter();
    VarInt::writeUnsignedInt($writer, $value);
    $reader = new ByteBufferReader($writer->getData());
    if (VarInt::readUnsignedInt($reader) !== $value || $reader->getUnreadLength() !== 0) {
        throw new RuntimeException("Unsigned VarInt round trip failed for $value");
    }
    if ($value === 300 && bin2hex($writer->getData()) !== 'ac02') {
        throw new RuntimeException('Unsigned VarInt wire encoding mismatch');
    }
}

foreach ([-2147483648, -1, 0, 1, 2147483647] as $value) {
    $writer = new ByteBufferWriter();
    VarInt::writeSignedInt($writer, $value);
    $reader = new ByteBufferReader($writer->getData());
    if (VarInt::readSignedInt($reader) !== $value || $reader->getUnreadLength() !== 0) {
        throw new RuntimeException("Signed VarInt round trip failed for $value");
    }
}

printf("PHP %s; encoding %s; 12 VarInt round trips and wire encoding passed.\n", PHP_VERSION, phpversion('encoding'));
