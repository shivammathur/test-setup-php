# Windows Server 2025 COM diagnostics

This orphan branch reproduces php-src `ext/com_dotnet/tests/bug64130.phpt`
with x86 PHP master builds on Windows Server 2022 and the GitHub-hosted
`windows-2025-vs2026` image.

## Conclusion

The unstable dependency is the legacy `InternetExplorer.Application` local
COM server, not PHP's by-reference marshalling. Windows Server 2025 retains the
IE compatibility payload and COM registration, but IE activation fails under
four-core saturation with HRESULT `0x8150002E`. The removed standalone IE
optional feature cannot be restored, and the IE mode capability is already
installed.

The deterministic replacement in `tests/com-local-server` is a native PE32
out-of-process COM server. It exposes the same `ClientToWindow([in,out] LONG*,
[in,out] LONG*)` automation contract and a `Quit()` method. The build registers
it only in the current user's 32-bit COM view as both
`PHPTest.LocalByRefServer` and `InternetExplorer.Application`, so the upstream
PHPT remains byte-for-byte unchanged and the machine registration is untouched.

Validation:

- Focused saturated `-j6` stress: 960 PHPT cases and 1,920 COM activations over
  two replicas each of Windows Server 2022 and 2025; no failures or skips.
  Run: https://github.com/shivammathur/test-setup-php/actions/runs/29151545564
- Exact php-windows-builder full extension harness at unchanged `-j6`: two TS
  and two NTS replicas, 15,890 tests per replica, zero failures/errors.
  `bug64130.phpt` ran normally in all four replicas. Run:
  https://github.com/shivammathur/test-setup-php/actions/runs/29151762864

The minimal php-windows-builder integration is to build and register this x86
helper before x86 extension tests on hosted runners and stop/unregister it in a
`finally` block. No PHPT patch, skip, retry, or worker reduction is needed.
