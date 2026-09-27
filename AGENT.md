# PHP Darwin maintenance

See `README.md` for usage and `docs/maintenance.md` for workflow operations.

- `conf/` defines versions, variants, platforms and archive policy.
- `conf/cached-extensions/<PHP minor>` lists one extension name per line.
  `conf/zend-extensions` identifies names loaded with `zend_extension`.
- `conf/extension-packs.json` defines optional packs, rebuilt independently from
  published PHP by `cache-extensions.yml`.
- Production code lives under `scripts/{build,cache,installer,release,lib}/`.
  Test suites and helpers live in `scripts/tests/`; templates live in `templates/`.
- `scripts/install.sh` is generated from `conf/install-files`; its public path is
  consumed downstream. Change its inputs and regenerate it rather than editing it.

```sh
bash scripts/installer/generate-install.sh
bash scripts/tests/run.sh
actionlint
```

`run.sh check` runs the build preflight; `unit` and `integration` select local
suites. Native cache and published-install checks run in GitHub Actions.

Builds prefer Cloudflare for bottles; normal PHP installs prefer GitHub Releases
with a checksum-verified Cloudflare fallback. Source-cache keys include formula,
dependency, platform and toolchain inputs. Archives include a pinned Homebrew tap
snapshot matching PHP; `tap_snapshot` is its path relative to the Homebrew prefix.

Installation preserves existing PHP kegs, configuration and services, and makes
cached PHP the default through the archived `bin/php` link. Compatibility gates
check correctness and preservation; timings are reported for separate performance
work, without blocking publication. Timing probes belong to test helpers; source
builds retain verbose configure/make output.
