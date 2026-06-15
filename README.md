# PHP artifact library QA

This orphan branch contains standalone GitHub Actions tests for PHP Windows build artifacts produced by `shivammathur/php-windows-builder` workflow `test-php-libs-from-source.yml`.

The workflow discovers the latest five completed successful source-build runs, validates that each has an unexpired `artifacts` bundle, downloads the bundle, and tests every `x64/x86` + `ts/nts` PHP zip inside it.

Coverage is intentionally outside php-src tests:

- `sqlite3` and `pdo_sqlite`: module surface, prepared statements, transactions, constraints, BLOBs, custom functions, aggregates, collations, backup, and optional SQLite3 serialize/authorizer APIs when present.
- `gd` AVIF/libavif: capability flags, file/stream/buffer encoding, decode paths, type detection, alpha/color roundtrip, quality/speed boundaries, and invalid input handling.
- `ldap` libsasl: real `ldap_sasl_bind()` using SASL PLAIN against a local mock LDAP server that validates the generated BER and credentials payload.

If cross-repository artifact access needs a broader token, set `PHP_WINDOWS_BUILDER_TOKEN` or `GH_TOKEN` in this repository. Otherwise the workflow falls back to `github.token`.
