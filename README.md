# Published Swoole pack validation

This orphan branch tests unchanged setup-php against published PHP Darwin caches
for PHP 5.6–8.5, ARM64 and Intel, and all release/debug and NTS/ZTS variants.
Each job checks cold and hot installations, the exact published archive identity,
PHP ABI, private module path, native linkage, preserved PHP/services, and Swoole
shared tables and event loops. Any source build during installation fails the test.

The workflow uses release installers; it does not substitute candidate installers
or rebuild PHP or Swoole. Per-job artifacts retain provenance and runtime reports.
