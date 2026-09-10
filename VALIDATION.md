# Validation results — 2026-09-10

Candidate: [`68a5222a8d935851c7d7f653041f2c1b25aaa228`](https://github.com/shivammathur/setup-php/commit/68a5222a8d935851c7d7f653041f2c1b25aaa228).

All 11 scenarios passed across two runs of the same candidate:

| Runner | Cache | ARM bottle fallback | ARM source fallback | Intel exit on cache failure |
| --- | --- | --- | --- | --- |
| macos-14 / arm64 | Passed | Passed | Passed | — |
| macos-15 / arm64 | Passed | Passed | Passed | — |
| macos-26 / arm64 | Passed | Passed | Passed | — |
| macos-15-intel / x86_64 | Passed | — | — | Passed |

The [initial matrix run](https://github.com/shivammathur/test-setup-php/actions/runs/34470431103) passed all eight cache, bottle and Intel-exit scenarios. Its three source scenarios failed because Homebrew rejected the deliberately unbottled core dependency before compilation. The test fixture was corrected to enable Homebrew developer mode only for those scenarios. All three passed in the [source rerun](https://github.com/shivammathur/test-setup-php/actions/runs/34471165295); the candidate did not change.

## Verified evidence

- All four images passed the complete 600-test suite, test type checks and action build.
- Cache lanes entered the actual cache installer and succeeded without Homebrew installation calls.
- The Intel failure lane exited immediately after the injected cache failure, without any Homebrew update or installation.
- ARM bottle lanes used bottled PHP and Argon2, with no source worker detected.
- ARM source lanes compiled the real Argon2 dependency after an injected 190-second silent command. Source workers were observed for 200 seconds on macOS 14, 202 seconds on macOS 15 and 203 seconds on macOS 26. These runs retained the production 180-second bottle and 1800-second source inactivity limits.
- Homebrew receipts identify Argon2 as built from source and PHP as poured from a bottle. PHP 8.4.25 successfully loaded its linked Argon2 library, generated and verified Argon2 hashes, ran SQLite queries, loaded the requested extensions and ini settings, and ran Composer. Binary architecture matched every runner.
- Separate real Homebrew source builds on all three ARM images validated successful compilation beyond the bottle timeout and stalled-build termination with exit 124 after two attempts. All recorded build workers were gone. Downloaded compiled artifacts were inspected as Mach-O arm64 binaries.

The deliberate timeout tests use accelerated 10-second bottle and 30-second source limits; no claim is made that a 30-minute stall was left running. Regression tests also cover switching back to the bottle timeout, retry recovery, complete descendant cleanup, partial output, disabled watchdogs, unrelated source workers and PHP failure propagation.

Receipts, injected formulas, path events, regression results, fixture logs and compiled binaries are uploaded as workflow artifacts with a 14-day retention period.
