# Full PHP source build and production timeout validation

This new orphan branch tests `shivammathur/setup-php@68a5222a8d935851c7d7f653041f2c1b25aaa228` on macOS 14, 15 and 26 ARM in parallel.

The disposable action reports a cache failure, then uses its normal Homebrew installation path. After the taps are refreshed, the fixture removes bottle definitions for **Argon2, libsodium, libzip, oniguruma, PCRE2 and PHP 8.4**. Existing copies of the five dependencies are removed. Developer mode permits the injected missing core bottles; Homebrew uses the system Git while PCRE2 is absent.

All five dependencies must compile and install successfully before PHP starts. PHP's complete formula install method then builds and installs its binaries, including its intl extension. The fixture preserves the compiled PHP CLI and deliberately stalls this first source attempt before Homebrew finalizes the installation. The stall ignores TERM and produces no output. The candidate must trigger its actual **1800-second source inactivity timeout**, kill the build process tree and retry. The second PHP attempt must compile and install successfully from source.

No watchdog timeouts or retry limits are overridden: bottles retain 180 seconds, sources get 1800 seconds, and the default retry limit is three. Verification requires exactly one timeout with exit 124, exactly one retry, no surviving captured processes, five source dependency receipts and a source PHP receipt. The second PHP build must start after cleanup completes.

Runtime checks exercise all five source libraries through PHP: Argon2 hashing, Sodium encryption, Zip archive creation/readback, Oniguruma regex and PCRE2 regex. SQLite, extensions, ini values, Composer, action output, Mach-O architecture and dynamic-library linkage are also checked.

Artifacts preserve both compiled PHP attempts, installed PHP binaries, five dependency libraries, receipts, original and patched formulas, source-build events, cleanup evidence and Homebrew logs. The workflow allows 150 minutes per runner for two full PHP builds plus the real 30-minute stall.
