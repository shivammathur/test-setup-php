php-xz
======

[![Build Status](https://travis-ci.org/codemasher/php-xz.svg?branch=master)](https://travis-ci.org/codemasher/php-xz)

PHP Extension providing XZ (LZMA2) compression/decompression functions.

## Installation

To install as module, perform the following steps:

```bash
git clone https://github.com/codemasher/php-xz
cd php-xz && phpize && ./configure && make && sudo make install
```

Do not forget to add `extension = xz.so` to your `php.ini`.

## Requirements

This module requires `git` and `liblzma-dev` as well as php7-dev. If you are using Ubuntu, you can easily install all of them by typing the following command in your terminal:

```bash
sudo apt-get install git php7.2-dev liblzma-dev
```

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
