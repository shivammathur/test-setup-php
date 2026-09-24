# Published macOS PHP caches through setup-php develop

An isolated orphan-branch integration test for PHP 5.6–8.7 on hosted macOS 15 ARM64 and Intel runners (28 jobs). It calls `shivammathur/setup-php@develop` directly, with verbose output, the published package cache, and Xdebug/PCOV where supported. It does not patch setup-php or preinstall the target cache.

Verification helpers are pinned to php-darwin d4ecfce. They check the cache tap and PHP version against the published manifest, preservation of existing PHP and service definitions, extension loading, absence of source/PECL rebuilds, and a strictly sub-10-second php-darwin installer invocation. Setup-php's bootstrap download and extension/configuration work are outside that installer measurement. Runtime, metadata, preservation snapshots and timing evidence are uploaded even when checks fail.

This test uses the currently published installers, including older installers for versions not yet refreshed. It can therefore identify which releases still need installer updates or further validation. There are no self-hosted runners registered to this repository; their validation remains in php-darwin.
