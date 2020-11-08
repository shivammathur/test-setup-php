# php-ext-xz

PHP Extension providing XZ (LZMA2) compression/decompression functions.

[![Build Status](https://travis-ci.org/codemasher/php-ext-xz.svg?branch=master)](https://travis-ci.org/codemasher/php-ext-xz)
[![Continuous Integration](https://github.com/codemasher/php-ext-xz/workflows/Continuous%20Integration/badge.svg)](https://github.com/codemasher/php-ext-xz/actions)

## Requirements

This module requires [`liblzma-dev`](https://packages.ubuntu.com/search?lang=de&keywords=liblzma-dev&searchon=names) (https://tukaani.org/xz/) as well as php7-dev or php8-dev.
If you are using Ubuntu, you can easily install all of them by typing the following command in your terminal:

```bash
sudo apt-get install git php7.4-dev liblzma-dev
```

## Installation

To install as module, perform the following steps:

```bash
git clone https://github.com/codemasher/php-ext-xz.git
cd php-ext-xz && phpize && ./configure && make && sudo make install
```

Do not forget to add `extension = xz.so` to your `php.ini`.

## Basic usage

```php
$fh = xzopen('/tmp/test.xz', 'w');
xzwrite($fh, 'Data you would like compressed and written.');
xzclose($fh);

$fh = xzopen('/tmp/test.xz', 'r');
xzpassthru($fh);
xzclose($fh);
```

```php
$str = 'Data you would like compressed.';

$encoded = xzencode($str);
$decoded = xzdecode($encoded);
```
