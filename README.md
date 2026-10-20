# Public PHP installation smoke tests

Tests the current public release of each supported PHP series using hash-pinned assets and native GitHub-hosted runners. The manifest records the release, asset ID, size, SHA-256 and GitHub digest where available. Assets without a GitHub digest were downloaded and SHA-256 pinned during preparation.

Coverage: PHP 5.6–8.5 from php-builder, php-ubuntu and php-darwin; PHP 7.2–8.5 from php-builder-windows. Ubuntu 22.04/24.04/26.04 on x64/ARM64, macOS ARM64/Intel, and Windows 2022 x64/x86; NTS/ZTS and available debug variants.

The checked-in installers consume the exact local archives. Tests check CLI/CGI/HTTP, FPM configuration, runtime identity, default loaded extensions, JSON/hash, OpenSSL, SQLite/PDO, ZIP, filesystem/session and execution with OPcache on/off. Windows uses production php.ini with the same explicit common extension configuration for every package.

Darwin content-addressed release assets are saved under their canonical names; the local checksum sidecar uses the verified manifest digest and canonical filename. Archive bytes are unchanged.

All payloads are public releases. Logs and result artifacts are retained in this repository. This is installation smoke coverage, not exhaustive PHP regression testing.
