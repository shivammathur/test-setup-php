# macOS cache and Homebrew timeout validation

Candidate: `shivammathur/setup-php@68a5222a8d935851c7d7f653041f2c1b25aaa228` (`fix/brew-source-timeout`).

[Completed validation results](VALIDATION.md): all 11 scenarios passed across the initial matrix and source-fixture rerun.

This is a new orphan test branch. All 11 scenarios are dispatched together by default. A manual dispatch with `scope=sources` reruns the three ARM source scenarios together.

| Runner | Cache | Cache failure -> Homebrew bottle | Missing dependency bottle -> source | Cache failure -> exit |
| --- | --- | --- | --- | --- |
| macos-14 (ARM) | yes | yes | yes | - |
| macos-15 (ARM) | yes | yes | yes | - |
| macos-26 (ARM) | yes | yes | yes | - |
| macos-15-intel | yes | - | - | yes |

The candidate's complete 600-test suite runs on all four runner images. It covers process-tree cleanup, detached build workers, TERM-resistant children, output without newlines, timeout switches, retry recovery and exhaustion, the watchdog opt-out, cache opt-outs, and PHP install/upgrade failure propagation.

Only a disposable action copy is instrumented. Cache lanes call the actual cache installer and require its success with no Homebrew install calls. Failure lanes return 37 from the cache installer. Intel must immediately exit and never update or install through Homebrew.

The ARM source lanes remove argon2's bottle block after Homebrew/core has been refreshed. Argon2 is a real PHP dependency. Only these test lanes enable `HOMEBREW_DEVELOPER=1`, allowing a fresh unbottled core dependency to build on ARM; otherwise Homebrew rejects this injected scenario before starting a compiler. Its source install starts with 190 seconds of silence, exceeding the unchanged 180-second bottle timeout. The default source timeout remains 1800 seconds. Homebrew then builds argon2 and installs PHP from its bottle. Receipts must identify argon2 as built from source and PHP as poured from a bottle.

On all three ARM images, additional isolated Homebrew installations compile a real fixture and validate source success past the bottle timeout, source timeout at its own limit, two-attempt exhaustion, and removal of every recorded build worker. These use 10/30-second limits; the full PHP dependency builds use the production 180/1800-second defaults.

All successful lanes validate PHP 8.4, action output, ini values, Composer, required extensions, SQLite queries, Argon2 hashing, Mach-O architecture, and linked libraries. Evidence includes branch provenance, path events, Jest results, Homebrew install receipts, the exact formula fault injection, source-build logs, and compiled fixture binaries.
