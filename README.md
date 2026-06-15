# PHP stable release library QA

This orphan branch contains standalone GitHub Actions tests for the latest stable PHP 8.2, 8.3, 8.4, and 8.5 Windows release artifacts from `downloads.php.net/~windows/releases`.

The workflow resolves the current stable releases from `https://www.php.net/releases/active.php`, downloads every `x64/x86` + `ts/nts` runtime zip for each minor version, and runs the same standalone library suite against them.

Coverage is intentionally outside php-src tests:

- `sqlite3` and `pdo_sqlite`: module surface, prepared statements, transactions, constraints, BLOBs, custom functions, aggregates, collations, backup, and optional SQLite3 serialize/authorizer APIs when present.
- `gd` AVIF/libavif: capability flags, file/stream/buffer encoding, decode paths, type detection, alpha/color roundtrip, quality/speed boundaries, and invalid input handling.
- `ldap` libsasl: real `ldap_sasl_bind()` using SASL PLAIN against a local mock LDAP server that validates the generated BER and credentials payload.
