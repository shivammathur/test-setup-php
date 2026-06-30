# zlib-rs extension compatibility QA

This orphan branch validates PHP Windows builds produced with zlib-rs against
extensions that were checked during the zlib/zlib-ng investigation.

The workflow uses the existing `shivammathur/php-windows-builder` zlib-rs PHP
build artifacts for PHP 8.2, 8.3, 8.4, and 8.5 with their matching Windows
2022 toolsets. It covers two paths in each PHP/architecture/thread-safety job:

- source-built extensions built with `php-windows-builder/extension` against
  those PHP artifacts, including the extension PHPT test phase for every tested
  extension
- available published Windows PECL extension binaries installed into the same
  zlib-rs PHP artifacts and smoke-tested as existing downstream binaries

The smoke job runs `php -v`, `php -m`, `php -i`, `php --ri`, and
`tests/zlib-extension-compat.php` for both source-built artifacts and PECL
binaries. The smoke test includes real zlib compression round trips, `zip`
archive creation, `pecl_http` deflate/inflate encoding streams, and memcached-backed
compressed set/get checks for `memcache` and `memcached`.

If a source extension builds but its upstream PHPT suite fails, the workflow
still collects the built DLLs for the smoke job and reports the upstream test
failure separately. Missing build output or missing collected artifacts still
fail the source job.

The zlib-rs compatibility gate is the smoke job. It validates the collected
source-built DLLs and loadable published PECL binaries with real gz, zlib stream
filter, zip, and extension compression round trips. Known missing or wrong-arch
published PECL binaries, or published PECL binaries with external runtime DLL
gaps, are reported separately; the PECL smoke then continues against the
remaining loaded extensions. The `memcached` smoke keeps the compressed set/get
round trip on 64-bit PHP; on 32-bit PHP it validates the compression option
surface because the stock-zlib baseline shows the same memcached client failures
before zlib-rs is involved.

The workflow also runs an informational x86 memcached PHPT baseline against a
stock-zlib PHP build so x86 libmemcached crashes can be compared with the
zlib-rs source-build results.
