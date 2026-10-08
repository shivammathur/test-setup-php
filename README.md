Validates php-builder PR #20 at 27307712 using artifacts from build 37794525615.

The original cases assert the reported FPM configuration gap and measure the Zend allocator through a FastCGI request. A green original case means the gap reproduced.

The patched cases apply fpm-runtime.patch to the source and repackage the original ASAN binaries with the resulting FPM service files. They verify a normal install without caller sanitizer variables, restart, the patched upstream SAPI test, and replacement with the matching regular package. Both systemd and SysV are tested on Ubuntu 22.04/24.04 AMD64/ARM64.

PHP binaries are reused unchanged; this does not rebuild PHP.
