# php-ext-xz

PHP Extension providing XZ (LZMA2) compression/decompression functions.<br/>
(see [Implement lzma (xz?) compression](https://news-web.php.net/php.internals/106654))

[![Linux build](https://github.com/codemasher/php-ext-xz/workflows/Linux/badge.svg)](https://github.com/codemasher/php-ext-xz/actions/workflows/linux.yml)
[![Windows PHP8 build](https://github.com/codemasher/php-ext-xz/workflows/Windows/badge.svg)](https://github.com/codemasher/php-ext-xz/actions/workflows/windows.yml)

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
Windows builds are now done automatically on each push; you can download them from the [build artifacts](https://docs.github.com/en/actions/managing-workflow-runs/downloading-workflow-artifacts) or [releases](https://github.com/codemasher/php-ext-xz/releases) (after 1.1.2).

If you want to build it on your own, follow the steps under "[Build your own PHP on Windows](https://wiki.php.net/internals/windows/stepbystepbuild_sdk_2)" to setup your build environment.
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

Please note that the `liblzma` dependency is not included with PHP < 8, so you will need to [download it manually](https://windows.php.net/downloads/php-sdk/deps/vs16/x64/liblzma-5.2.5-vs16-x64.zip) and extract it into the `deps` directory.

Copy the `php_xz.dll` into the `/ext` directory of your PHP installation and add the line `extension=xz` to your `php.ini` or in case of the versioned .dll from the artifacts something like: `extension=xz-0eebbf2-8.2-ts-vs16-x64` - omit the `php_` and `.dll`.

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
