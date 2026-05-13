# libffi PHP QA

This orphan branch contains a standalone GitHub Actions workflow for validating
`libffi-3.5.2` Windows artifacts against the latest Windows PHP 8.2, 8.3,
8.4, and 8.5 release zips.

The tests are custom C and PHP FFI tests, not php-src PHPTs. The workflow:

- downloads `libffi-3.5.2-vs16-{x86,x64}` and `libffi-3.5.2-vs17-{x86,x64}`;
- sanity-checks the packaged headers for `FFI_STATIC_BUILD`, `FFI_BUILDING`,
  version `3.5.2`, and `FFI_VECTORCALL_PARTIAL`;
- compiles a direct MSVC executable against the artifact;
- compiles a DLL against the artifact and loads it from PHP FFI;
- runs scalar, struct, varargs, closure/callback, calling convention, guard-page
  overread, and register-mix tests;
- compares the same test set across PHP 8.2 through 8.5 and both x86/x64.

If the cross-repository artifact download needs a broader token, add a repository
secret named `WINLIBS_ACTIONS_TOKEN` with read access to `winlibs/winlib-builder`.
