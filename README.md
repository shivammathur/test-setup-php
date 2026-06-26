# Winlibs Dependency Exhaustive QA

This orphan branch validates the PHP artifacts from the pre-rerun
`shivammathur/php-windows-builder` source builds that used the upgraded Winlibs
dependency set:

| PHP | Source run |
| --- | --- |
| 8.2 | `28210572357` |
| 8.3 | `28210572138` |
| 8.4 | `28210572127` |
| 8.5 | `28210572154` |
| master | `28210572141` |

The workflow downloads each aggregated `artifacts` bundle and runs every PHP
runtime variant in it: `x64/x86` and `ts/nts`.

The manual-driven coverage checklist is in
[`docs/winlibs-deps-exhaustive-checklist.md`](docs/winlibs-deps-exhaustive-checklist.md).

The suite covers the PHP surfaces backed by these Winlibs dependencies:

- `libcurl` through `ext/curl`
- `libffi` through `ext/ffi`
- `glib` through direct FFI calls into the packaged GLib runtime DLL
- `libenchant2` through `ext/enchant`
- `ICU/icu4c` through `ext/intl`
- `libjpeg-turbo` through `ext/gd` JPEG support
- `libtidy` through `ext/tidy`
- `wineditline` through `ext/readline` when the artifact exposes that userland extension; otherwise the suite records that no PHP userland readline surface is present
