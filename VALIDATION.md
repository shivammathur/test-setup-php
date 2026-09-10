# Full source validation — passed

[Workflow run 34472933163](https://github.com/shivammathur/test-setup-php/actions/runs/34472933163) passed on all three ARM runners.

Candidate: [`shivammathur/setup-php@68a5222a8d935851c7d7f653041f2c1b25aaa228`](https://github.com/shivammathur/setup-php/commit/68a5222a8d935851c7d7f653041f2c1b25aaa228). Tested harness commit: `5fa09138ec8668db2dcc95103a2e2789ddab0893`.

| Runner | Successful source installs | Observed silent stall | Watchdog status | PHP source attempts | Result |
| --- | --- | --- | --- | --- | --- |
| macOS 14 ARM | Five dependencies + PHP | 1802 seconds | 124 | 2 | Passed |
| macOS 15 ARM | Five dependencies + PHP | 1802 seconds | 124 | 2 | Passed |
| macOS 26 ARM | Five dependencies + PHP | 1800 seconds | 124 | 2 | Passed |

Every runner built and installed these packages from source:

| Package | Version |
| --- | --- |
| Argon2 | 20190702, revision 1 |
| libsodium | 1.0.22 |
| libzip | 1.11.4, revision 1 |
| oniguruma | 6.9.10 |
| PCRE2 | 10.48 |
| PHP | 8.4.25, revision 1 |

The five dependencies finished before PHP started. The first PHP attempt completed the full formula install method, including intl, and saved a runnable compiled PHP binary. A deliberately silent, TERM-resistant shell then stalled the source worker. The unchanged 1800-second inactivity watchdog terminated that attempt. Cleanup completed before the next attempt, and the second complete PHP source build installed successfully. Each runner recorded exactly one timeout, one retry, no third attempt, and no surviving recorded processes.

All six Homebrew receipts on each runner report `poured_from_bottle: false` and `built_as_bottle: false`. PHP successfully exercised the five source libraries through Argon2 hashing, Sodium encryption, Zip creation/readback, Oniguruma regex and PCRE2 regex. SQLite, requested extensions, ini settings, Composer, action output, PHP-CGI, phpdbg and PHP-FPM configuration checks also passed.

Downloaded artifacts were inspected locally: all 36 installed binaries/libraries matched their recorded SHA-256 values and were Mach-O arm64 files. Both compiled PHP attempts from every runner were also inspected. First-attempt build logs survive independently of the retry's logs.

The test used the actual production timeouts: **180 seconds for bottles and 1800 seconds for source builds**. Neither timeout nor the three-attempt retry limit was overridden.

The [initial run](https://github.com/shivammathur/test-setup-php/actions/runs/34472659086) stopped before compilation because the downloaded PHP tap was root-owned. The harness was corrected to patch that single formula through `sudo tee`; the candidate implementation did not change. All three corrected scenarios were rerun together.

[Machine-readable results and artifact hashes](validation.json) are retained in this orphan branch. Full formulas, receipts, logs, compiled PHP attempts and dependency libraries are attached to the successful workflow with a 14-day retention period.
