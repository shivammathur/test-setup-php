# Pre-dispatch reviews

## Pass 1 — public surface and feature coverage

Compared public method inventories against the six exact PHP source stubs recorded in `api-manifest.json`; no php-src tests were copied. Checked the SQLite 3.54.1 function/module inventories against submitted SQL and behaviour assertions. Added missing direct-query, extension-loading, legacy PDO callback, FTS4 auxiliary vocabulary, PRAGMA, backup/attachment and statement-state cases. Coverage gates require all public methods, all exposed SQL function names and all nine Windows modules.

## Pass 2 — assertions, edge cases and portability

Checked NULL/type coercion, domain errors, malformed inputs, empty aggregates, percentile boundaries and windows, Unicode/NUL/BLOB data, constraint rollback, callbacks, read-only access, version-specific APIs, x86-safe integer checks and native/PDO differences. Added separate-process lock/rollback and WAL snapshot tests, cross-driver persistence, large BLOB checks, RTREE rounding and deferred foreign keys. Fixed assumptions about JSONB bytes, PHP deprecations, SQLite3 statement stepping and defensive mode. Local execution used PHP 8.6 and SQLite 3.54.1; Windows matrix results are recorded separately.

## Pass 3 — harness and workflow review

Reviewed exact run/ZIP/binary provenance, six matrix mappings, compiler/architecture fixture selection, isolated PHP INI/PATH, actual loaded DLL verification, OPcache activation, timeouts, failure propagation and report completeness. Actions are pinned to verified commits; permissions are read-only; jobs continue independently on failure. Every variant and OPcache mode is attempted, and JSON/JUnit plus diagnostics upload even after failures. Report gates reject missing coverage, failed/empty/inconsistent reports, wrong versions/bitness and wrong hashes. Harness self-tests cover false assertions, exception expectations, SQL string/comment exclusion and binary-safe failure reporting. Twelve runner fault-injection checks verify rejection paths before artifact tests run.

No workflow was dispatched before these three reviews and local PHP/C/PowerShell/workflow checks.
