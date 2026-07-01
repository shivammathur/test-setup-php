# libbzip2 PHP Artifact Benchmark

This orphan branch benchmarks PHP source-build artifacts that use bzip2-rs-backed
`libbzip2` against older successful PHP source-build artifacts that used the
normal downloads.php.net dependency packages.

The workflow benchmarks `ext/bz2` and, when available, `ZipArchive::CM_BZIP2`
for `PHP-8.2`, `PHP-8.3`, `PHP-8.4`, `PHP-8.5`, and `master`, across `x64/x86`
and `nts/ts` PHP builds.
