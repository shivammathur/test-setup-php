# php-ext-xz

PHP Extension providing XZ (LZMA2) compression/decompression functions.<br/>
(see [Implement lzma (xz?) compression](https://news-web.php.net/php.internals/106654))

[![Continuous Integration](https://github.com/codemasher/php-ext-xz/workflows/Continuous%20Integration/badge.svg)](https://github.com/codemasher/php-ext-xz/actions)

## Build & Installation

### Linux

This module requires [`liblzma-dev`](https://packages.ubuntu.com/search?lang=de&keywords=liblzma-dev&searchon=names) (https://tukaani.org/xz/) as well as php7-dev or php8-dev.
If you are using Ubuntu, you can easily install all of them by typing the following command in your terminal:
```bash
sudo apt-get install git php7.4-dev liblzma-dev
```
To build and install as module, perform the following steps:
```bash
git clone https://github.com/codemasher/php-ext-xz.git
cd php-ext-xz
phpize
./configure
make
sudo make install
```

Do not forget to add `extension=xz.so` to your `php.ini`.

### Windows

Follow the steps under "[Build your own PHP on Windows](https://wiki.php.net/internals/windows/stepbystepbuild_sdk_2)" to setup your build environment.
Before the compilation step, clone this repository to `[...]\php-src\ext\xz` and proceed.

```bat
git clone https://github.com/Microsoft/php-sdk-binary-tools.git c:\php-sdk
cd c:\php-sdk
phpsdk-vs16-x64.bat
```
Run the buildtree script and check out the php source:
```bat
phpsdk_buildtree php-8.0
git clone https://github.com/php/php-src.git
cd php-src
git checkout PHP-8.0
```
Clone the xz extension and run the build:
```bat
git clone https://github.com/codemasher/php-ext-xz .\ext\xz
phpsdk_deps -u
buildconf --force
configure --enable-xz
nmake snap
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

## Disclaimer
May or may not contain bugs. Use at your own risk.
