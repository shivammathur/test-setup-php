# Tensor 3.1.0 / OpenBLAS 0.3.34 final artifact check

Tests the existing, unchanged Tensor DLLs from
[php-windows-builder run 35486736634](https://github.com/shivammathur/php-windows-builder/actions/runs/35486736634).
No Tensor or OpenBLAS rebuild is performed and no package is published.

- All 24 release configurations: PHP 8.0–8.5, x86/x64, TS/NTS.
- Each bundled OpenBLAS DLL must match its published 0.3.34 VS16/VS17 package.
- Four additional cases use the same PHP 8.5 Tensor DLLs with the published
  0.3.34 VS18 DLLs. These check the VS18 dependency, not PHP 8.6 compatibility.
- PHPUnit 9.6.36 runs the tests from Tensor tag 3.1.0, pinned to
  `94cd025562b4edcd968e1c26b67a8751cb42f39a`.
- The bootstrap verifies that all nine tested Tensor classes are native.
  PHPUnit failures, empty/incomplete suites and an ABI mismatch fail the job.
- SHA256 pins cover every original Tensor ZIP/DLL, all six published OpenBLAS
  ZIPs/DLLs and the PHPUnit PHAR. License copies are verified as well.

`qa/artifacts.json` records the original artifacts and dependency hashes.
Every job uploads its JUnit report, text output, results and provenance.

## Results

[Run 35488208073](https://github.com/shivammathur/test-setup-php/actions/runs/35488208073)
finished with **22 passing jobs and six failing jobs**. Every job ran 394 tests
and 622 assertions with four upstream skips. The failures were not suppressed
or retried until green. All 28 downloaded JUnit/provenance reports were inspected.

| Tensor configuration | OpenBLAS | Result |
| --- | --- | --- |
| PHP 8.0, x86/x64, TS/NTS | Bundled VS16 | 4 passed |
| PHP 8.1–8.3, x64, TS/NTS | Bundled VS16 | 6 passed |
| PHP 8.1–8.3, x86, TS/NTS | Bundled VS16 | 6 failed |
| PHP 8.4–8.5, x86/x64, TS/NTS | Bundled VS17 | 8 passed |
| PHP 8.5, x86/x64, TS/NTS | Published VS18 substitution | 4 passed |

All six failures are `Tensor\Tests\VectorTest::convolve`, with `NaN` at output
index 8 instead of `1764.3000000000002`; see an
[example failure](https://github.com/shivammathur/test-setup-php/actions/runs/35488208073/job/106018349387).

Tensor's
[`tensor_convolve_1d`](https://github.com/RubixML/Tensor/blob/94cd025562b4edcd968e1c26b67a8751cb42f39a/ext/include/signal_processing.c#L47)
uses `jmax = i <= na ? i : na - 1`, then loops through `j <= jmax`. At `i == na`
it reads `va[na]` past the `na` allocated doubles. This matches the failing
index for the eight-element test vector. The function does not call OpenBLAS.
The source file in the actual PECL 3.1.0 package is byte-identical to the linked
tag file (SHA256 `d10f751df6124c8733f54aa97d428ed990fe4751f34b5f477c2bc4be53ee9289`).

This is an out-of-bounds read in Tensor, not a clean all-green consumer sign-off.
Passing configurations do not make that undefined behavior safe. No extension
source, DLL, assertion or skip condition was changed to work around the failure.
