# SQLite 3.54.1 PHP userland tests

Original application-level tests for PHP's `SQLite3`, `PDO_SQLite` and `Pdo\Sqlite` APIs. These are ordinary PHP programs, not php-src/PHPT tests.

The suite exercises every public method in the supported PHP versions and every SQL function name exposed by the Windows builds. Runtime inventories reject untested additions. Tests cover scalar/math/date functions, aggregates and windows, percentile calculations, JSON/JSONB, FTS3/4/5, RTREE, DBSTAT, bindings, fetch modes, callbacks, authorizers, extension loading, BLOB streams, backups, schema changes, transactions, persistence, locks and WAL snapshots.

Windows validation uses the six source-build runs pinned in `artifacts.json`: PHP 8.2 through 8.6 and master (8.7), x86/x64, TS/NTS, with OPcache off/on. ZIP and binary hashes, PE architecture, SBOM version, SQLite source ID and the loaded SQLite DLL path are checked. Each run produces JSON results, API/function/module coverage, JUnit and logs.

To run against an extracted Windows build, use the workflow on this branch. To run locally with SQLite 3.54.1, enable `sqlite3` and `pdo_sqlite`, compile `tests/sqlite/extension/qaextension.c` as a shared library, set `SQLITE_QA_EXTENSION` to its absolute path, and set `sqlite3.extension_dir` to its canonical directory:

```sh
SQLITE_QA_EXTENSION=/absolute/path/qaextension.so php \
  -d sqlite3.extension_dir=/absolute/path \
  tests/sqlite/run.php --work=/fresh/work/directory --report=/output/reports
```

Use a fresh work directory for each invocation. PHP 8.2–8.7 are supported; newer public APIs require a reviewed manifest update. On non-Windows development runs, the Homebrew-only GEOPOLY module and its functions are outside this suite, and FTS4 is tested by behaviour when its compile-option marker is absent.

SQLite3's prepared-statement API can execute a statement again when its result is fetched. The suite avoids fetching resultless DML and uses `querySingle()` for native `RETURNING` examples. Legacy PDO SQLite aliases are tested with their expected PHP 8.5+ deprecation notices. Native SQLite3's defensive mode rejects `journal_mode=OFF`; the suite checks that restriction.

Coverage means tested API methods and function names plus the listed scenarios. It does not claim every possible input, query plan, platform, SQLite compile-time extension, crash/power-loss condition or internal C API. Process tests cover locking and rollback after an uncommitted process exit; they are not power-loss durability tests.
