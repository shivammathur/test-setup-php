# libffi 3.3 to 3.5.2 PHP/Windows Coverage

This branch is scoped to Windows PHP builds and the `libffi-3.5.2` artifacts from `winlibs/winlib-builder`.
The source review used `ChangeLog`, `include/ffi.h.in`, `src/x86/ffitarget.h`, `src/x86/ffi.c`, `src/x86/ffi64.c`,
`src/x86/ffiw64.c`, `src/closures.c`, `src/prep_cif.c`, `src/tramp.c`, and the tests added upstream between
`libffi-3.3` and `libffi-3.5.2`.

| Changelog area | PHP/Windows risk | Workflow coverage |
| --- | --- | --- |
| 3.4.0 single-entry, small, nested, and closure struct tests | Struct return and by-value behavior can break PHP FFI calls | `structs/return-two-byte-struct`, `structs/pass-two-byte-struct`, `structs/return-int-double-struct`, `structs/pass-int-double-struct`, `structs/return-big-struct`, `structs/pass-big-struct`, PHP `php-ffi-structs/*` |
| 3.4.3 win32 ABI handling for struct return | x86 PHP builds need correct MSVC ABI behavior | x86 matrix with `calling-conventions/x86-ms-cdecl`, `x86-stdcall`, `x86-fastcall`, struct by-value and struct return cases |
| 3.4.3 temporary executable/trampoline cleanup | Closures and callbacks can fail or allocate non-executable trampolines | `closures/call-prepared-closure`, PHP `php-ffi-callbacks/php-closure-to-c-callback`, `artifact-self-via-php/dll-self-test-exit` |
| 3.4.4 `FFI_API` static build fix | Static artifacts must not force `dllimport` into PHP or consumers | Workflow header sanity check for `FFI_STATIC_BUILD`/`FFI_BUILDING`, direct MSVC static link of `ffi_probe.exe`, DLL linked with artifact and loaded from PHP |
| 3.4.5/3.4.6 long double symbol fixes | PHP references `ffi_type_longdouble`; MSVC should alias it safely to double | `metadata/long-double-symbol` |
| 3.4.5 single-element and larger struct handling | PHP FFI passes C structs of different sizes | small, pair, and big struct direct artifact tests plus PHP FFI struct tests |
| 3.4.8 x86-64 small argument overread fix | A PHP FFI scalar call near a page boundary must not crash | `memory-safety/guarded-u8-argument` uses a protected guard page |
| 3.4.8 x86-64 GP/SSE register mix fixes | Mixed integer/floating argument calls are common through PHP FFI | `registers/gp-sse-mixed-arguments`, `scalar/mixed-int-float-double`, PHP `php-ffi-calls/mixed-scalar-call` |
| 3.4.8 Microsoft ABI attribute fixes | MS ABI calls need the right calling convention metadata | `calling-conventions/*` including stdcall, fastcall, ms_cdecl, win64, and vectorcall-partial where applicable; x86 vectorcall is checked against the integer subset from the partial fastcall-backed implementation |
| 3.5.0 version API | Consumers may check libffi version at runtime | `metadata/version-string`, `metadata/version-number`, PHP `artifact-metadata-via-php/version-*` |
| 3.5.0 closure size/default ABI API | PHP-facing consumers can use the new API to validate runtime ABI | `metadata/default-abi-range`, `metadata/closure-size`, PHP `artifact-metadata-via-php/default-abi`, `closure-size` |
| 3.5.0 Windows build fixes | Artifact must be consumable by MSVC for PHP-relevant x86/x64 toolsets | Matrix covers PHP 8.2/8.3 on `vs16` and PHP 8.4/8.5 on `vs17`, both `x86` and `x64` |
| 3.5.2 wasm64, DragonFly, `O_CLOEXEC`/tramp descriptor changes | Not directly used by Windows PHP artifacts | Recorded as reviewed; no executable Windows PHP assertion beyond closure/trampoline regression coverage |
| Upstream testsuite additions: callbacks, varargs, overread, struct-by-value, return integer sizes | PHP FFI exercises the same call classes | `closures/*`, `varargs/prep-cif-var-int-sum`, `memory-safety/*`, `structs/*`, `scalar/*` |

The Windows/PHP-relevant upstream test additions are represented by purpose-built probes rather than copied PHPTs or DejaGNU tests:

- `scalar/return-uint8`, `scalar/return-sint16`, and `scalar/return-sint64` cover the return-width tests added upstream.
- `structs/return-single-entry-struct`, `structs/pass-single-entry-struct`, `structs/return-nested-struct`, and `structs/pass-nested-struct` cover the single-entry and nested struct changelog/testsuite changes.
- `varargs/prep-cif-var-int-sum` and `varargs/prep-cif-var-double-sum` cover fixed plus variadic argument preparation with integer and promoted floating arguments.
- `closures/call-prepared-closure` and PHP `php-ffi-callbacks/php-closure-to-c-callback` cover closure allocation, callback invocation, and trampoline usability from both C and PHP.

Platform-specific changes for wasm, DragonFly BSD, AArch64 PAC/BTI, PowerPC/s390 static trampolines, MIPS, LoongArch, OpenRISC, Solaris, Darwin-only x86 struct returns, Android Go closures, and removed Nios II support were reviewed from the changelog and diff, but they are not executable against the Windows `vs16`/`vs17` PHP artifacts. The closest Windows-facing regression checks for those shared areas are closure/trampoline allocation, static linking, header/API checks, and direct DLL loading from PHP.

The workflow deliberately does not run php-src PHPTs. It writes and runs its own C/libffi probe and PHP FFI script, then
compares results across the latest Windows PHP 8.2, 8.3, 8.4, and 8.5 release zips.
