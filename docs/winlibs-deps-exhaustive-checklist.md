# curl 8.23.0 and FreeType 2.15.0 artifact qualification

This execution uses a new orphan branch and exact artifact runs. `native-matrix.json` pins the dependency builds; PHP QA takes an explicit JSON matrix of source build run IDs (the initial matrix is in `candidate-php-matrix.json`). No released PHP fallback is permitted.

- All dependency toolsets and x86/x64/ARM64: record artifact file hashes; execute curl; check SMB/SMBS download, upload, reuse, escaped paths, empty/missing files, wrong credentials, and TLS certificate rejection. PHP 8.6/master must reject both schemes as unsupported.
- FreeType: compile a native probe against the exact candidate static library and the previous published 2.14.3 static library on the same runner. Render at least 4,032 glyphs over three or more Windows fonts and six sizes; retain all metrics and bitmap hashes for review. Differences are reported for inspection because hinting changes can be intentional.
- Candidate FreeType: exercise the fixed oversized variable-coordinate read with a synthetic one-axis font and verify all 63 extra outputs are zero. Baseline avoids the known unsafe call.
- Every PHP branch: four exact x86/x64 TS/NTS ZIPs; curl API/feature/protocol checks, HTTP/multi/share/file operations, GD JPEG operations and FreeType font/size/rotation/Unicode coverage. Native SMB checks also run through PHP's curl extension.
- Record runtime ZIP hashes and all executable/DLL/SBOM hashes for comparison to source build downloads. Require curl 8.23.0 and FreeType 2.15.0.
- Inspect all upstream source-test JUnit results separately, including failures masked by continue-on-error.
- Repeat PHP artifact QA using normal staging-resolved source builds after publication and canonical URL verification.

The synthetic font generator is copied from FreeType 2.15.0 `tests/issue-1469/make-fonts.py`. Its FreeType license files are included under `native/`.
