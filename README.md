# GH-24335 Windows validation

Compare PHP-8.4 at `25348e809d4e2ec89c6de562d22c876e4ab90a1d`, which includes the merged quoting fix GH-24343, with the same commit plus the exact one-line C patch from GH-24335 (`b80923b370a11ce07ed7c2192a3e282cc0db229b`).

Both jobs use upstream Windows 2022 x64 ZTS snapshot-build configuration, dependencies, service setup and complete tracing-JIT test suite. The runner's `--bless` option is replaced with per-test result recording to retain failures without rewriting expectations. Run all `proc_open*.phpt` tests separately without INI and with tracing JIT. A native child verifies real reads/writes on each null standard handle, and all three together, using both shell and array commands.

The baseline's native probe is diagnostic: its failure is expected if it reproduces the inheritance bug. The patched probe must pass. Both lanes require the full suite and focused tests to pass. Artifacts contain source/patch provenance, compiled PHP binaries and hashes, complete logs, per-test results and failed-test output/diffs.
