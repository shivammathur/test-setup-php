# Maintenance

## Layout

| Path | Responsibility |
| --- | --- |
| `.github/actions/`, `.github/workflows/` | Actions integration and orchestration |
| `conf/` | Versions, variants, platforms, archive policies and installer inputs |
| `scripts/build/` | Formula inputs, build preparation, packaging and reports |
| `scripts/cache/` | Upstream/source bottles, build locks and archive checkpoints |
| `scripts/installer/` | Installation helpers and standalone installer generator |
| `scripts/release/` | Update detection, publishing and mirroring |
| `scripts/lib/` | Shared shell, HTTP, hashing and metrics helpers |
| `scripts/tests/` | Regression tests, native checks, fixtures and test helpers |
| `templates/` | JSON and installer substitution templates; no runnable helpers |
| `scripts/install.sh` | Generated standalone installer; public path must remain stable |

Edit source helpers and `conf/install-files`, then regenerate the installer.
Never edit the generated file directly. It embeds readable shell and configuration
and needs no repository checkout or Node runtime during installation.

## Checks

```sh
bash scripts/installer/generate-install.sh
bash scripts/tests/run.sh check        # Syntax, configuration and generated output
bash scripts/tests/run.sh unit         # Isolated cache and reporting behavior
bash scripts/tests/run.sh integration  # Local CLI, filesystem and HTTP fixtures
bash scripts/tests/run.sh              # All local checks
# Requires actionlint and shellcheck on PATH:
actionlint
```

Local tests use temporary directories and simulated commands. Keep credentials
and real Homebrew mutation out of these suites. Names use `*.test.sh` or
`*.test.cjs`; group tests by purpose, not language. Add fixtures only when they
protect behavior that is not already covered. Test output belongs in temporary
directories or Actions artifacts, not checked-in benchmark reports.

`test-source-cache.yml` exercises real library/consumer source builds, locking,
configuration preservation and Xdebug/PCOV cold/warm reuse. Its release is
isolated per run and removed by its cleanup job. `test.yml` validates all four
variants from an existing build's artifacts. `e2e.yml` checks published downloads
and unchanged setup-php on ARM and Intel. Routine Intel jobs use `macos-15-intel`;
dedicated self-hosted coverage is a separate one-time check after installer
changes are ready.

```sh
gh workflow run test-source-cache.yml -R shivammathur/php-darwin
gh workflow run test.yml -R shivammathur/php-darwin \
  -f php-version=8.4 -f run-id=BUILD_RUN_ID -f runner=macos-15-intel
gh workflow run e2e.yml -R shivammathur/php-darwin -f php-version=8.4
```

Tests in `native/` and `e2e/` require workflow-provided state and are not part of
the local runner. Run all applicable suites after installer, cache or workflow
changes, and inspect artifacts and logs as well as job conclusions.

GitHub API steps use the repository's `TOKEN` Actions secret when configured,
with `github.token` as the fallback. Reusable workflows pass `TOKEN` explicitly.
The token needs repository contents and Actions access for release and workflow
operations; keep its value only in Actions secrets.
Push-triggered validation runs only on branches. Keep release tags excluded:
tags created with `TOKEN` emit push events and can recursively start cache tests.

## Build and cache

Each `conf/cached-extensions/<PHP minor>` file contains plain extension names,
one per line. `conf/zend-extensions` lists names requiring the `zend_extension`
INI directive; other names use `extension`. These are build inputs, not runtime
installer configuration.

`conf/versions`, `conf/variants` and `conf/platforms.json` are authoritative.
Builds pin the PHP and extension taps and Homebrew core, run each architecture/variant independently, then
publish only after required compatibility jobs pass. Stable/nightly update
workflows compare relevant formula, runtime dependency, packaging and php-src
inputs before dispatching work. Package metadata records normalized recipe
inputs; new bottles for unrelated platforms do not invalidate existing caches.
An older manifest without dependency provenance requires a controlled refresh.
Compression settings and installer-only changes do not invalidate PHP packages.

```sh
gh workflow run cache-bottles.yml -R shivammathur/php-darwin -f seed=true
gh workflow run cache-source-bottles.yml -R shivammathur/php-darwin -f seed=true
gh workflow run cache-stable.yml -R shivammathur/php-darwin -f php-version=8.4
```

During builds, exact upstream bottle digests are read from Cloudflare into
Homebrew's download cache. Misses fall back to Homebrew's concurrent upstream
fetch and are mirrored afterward, one dependency per job. Retain current bottle
downloads on persistent runners. Never substitute an older bottle for a new digest.

Packages without usable upstream bottles use the `cache` GitHub Release for
source-build metadata and locks. Their bundles also use Cloudflare first.
Keys include software and dependency versions plus the target platform; PHP
extensions additionally include the PHP API and variant. Nightly PHP source
commits identify their software version. Recipe bytes and runner toolchain
changes do not invalidate source bottles. Legacy keys remain readable, with
checksum and software identity verification before reuse. Existing configuration
is restored after source bottling, including failed builds; service data is not staged. Keep configure/make output visible.

Archive checkpoints last seven days and require matching software inputs and
verified payloads. The php-darwin repository revision is provenance only.
Checkpoints are separate from reusable source bottles.
Partial reruns can restore a checkpoint before installing PHP when the run,
pinned taps/core, architecture, variant and toolchain match. Other runs retain
the installed-payload comparison. Missing or invalid checkpoints fall through
to the normal cache/build path.
Archives use Zstd level 19 with `--long=27`; Actions uploads use compression level
zero. Preserve runtime/development files and licenses under the archive policy.
A five-round PHP 8.5 [macOS benchmark](https://github.com/shivammathur/test-setup-php/actions/runs/36280295251)
compared levels 10, 15, 17 and 19 using identical tar contents. Level 19 had the
fastest median download/hash/extraction on ARM (2.25 seconds); Intel level 17
was only 0.15 seconds ahead (6.24 versus 6.39), within the observed variation,
while adding about 5 MB. These are transfer/extraction timings, not total
installer durations. Keep level 19; the temporary benchmark workflow and
release fixtures were removed, with measurements retained as Actions artifacts.

## Publish and installer updates

The installer runs one PHP loader smoke test before committing. Version
identification uses php-config. A failed rollback retains its transaction
directory and reports the recovery path; backups never become release assets
or R2 objects. Compatibility jobs upload rollback diagnostics as workflow
artifacts, excluding the backed-up user files.

Recovery publication validates source workflow provenance, the expected matrix,
successful jobs across attempts, and exact artifact IDs/digests. New runs save
their build plan; older runs use their own checked-in platform configuration.

Optional extension publication verifies replacement archives on both origins
before updating manifests. Cleanup protects the union of both manifests during
partial publication, then removes superseded GitHub assets and R2 objects.
Preflight cleanup reserves release capacity; post-publication cleanup failures
are reported and retried on the next publication. An installer with a retired
archive refreshes its manifest once. Installer-only extension publication also
reclaims archives left unreferenced by older publishers.

Use `e2e.yml` with `checkout-installer=true` to test candidate installer bytes
against existing published packages. setup-php first runs without installed PHP,
then repeats on the hot path; optional packs must come from the private cache.
Standalone E2E runs require optional packs by default. The PHP publication
workflow tests the PHP archive and bundled coverage modules immediately;
optional packs have separate compatibility gates and can still target the
previous PHP patch or nightly commit until their own publication completes.
The action source remains unchanged. The harness supplies hosted-runner context
on repository self-hosted macOS machines and requires cache-installer timing
evidence, because stock setup-php skips the cache on self-hosted installations.
Performance experiments belong on a new
orphan branch in `shivammathur/test-setup-php`; compare download, verification,
extraction and installation, with timing reports retained as workflow artifacts.
If only compression changes, recompress existing tar bytes on Ubuntu, verify
their decompressed hashes, republish, and remove the temporary workflow. Do not
compile PHP solely to change compression.

Each `php-X.Y` release contains eight architecture/variant archives, a manifest
and `install.sh`. The `tap_snapshot` setting is the archive path
`var/php-darwin/homebrew-php`, relative to the Homebrew prefix. It contains a
shallow Git copy of the exact PHP tap used to build the cache, including formulae
and their shared definitions. The installer validates this snapshot, keeps a
matching installed tap, or uses the bundled tap while preserving existing user
state. This avoids a tap download and mismatched formula definitions during
installation. The snapshot is generated during packaging, not stored in this
repository.

Archives have immutable checksum-addressed names. Verify
checksums, metadata, the complete matrix and public Cloudflare copies before
publishing the installer and manifest. Preserve the manifest schema and asset names.

R2 uses the `php-darwin` bucket and these repository secrets:

- `CF_R2_AWS_ACCESS_KEY_ID`
- `CF_R2_AWS_SECRET_ACCESS_KEY`
- `CF_R2_AWS_S3_ENDPOINT`

The public mirror is `https://artifacts.php-darwin.setup-php.com`. PHP packages
live under `php-X.Y/`; dependency objects live under `homebrew/bottles/sha256/`
and `homebrew/source-bottles/sha256/`. Build locks require `contents: write`
and `actions: read`; archive checkpoint pruning also needs `actions: write`.
Source bottles use named releases: `cache-php`, `cache-imagick`, `cache-mongodb`,
`cache-memcached`, and one `cache-<extension>` release for each other extension.
Shared libraries stay in `cache`. Filenames and display labels identify package
version, macOS, architecture and PHP variant; exact keys and checksums remain intact.
Build claims use `cache-locks` so they cannot exhaust bottle storage. This avoids
GitHub's 1,000-assets-per-release limit without deleting reusable builds.
Ownership reads retry every error up to three attempts, then fail without
deleting the existing claim. A network outage never authorizes a second builder.
Healthy owners remain protected throughout the coordination deadline.
CI repairs an inherited shallow core tap before pinning or timing E2E installs,
preserving its checked-out revision and keeping `brew update` usable.

Before Homebrew operations, self-hosted macOS jobs run a bounded process preflight.
It only recovers an orphaned portable-Ruby Homebrew install/reinstall/upgrade owned
by the runner user, started before the current job, and holding an exclusive lock
in that architecture's Homebrew prefix. Recovery requires exactly one active
`Runner.Worker` and proves it is the current action's ancestor. Other active jobs,
services, newer processes and ambiguous owners are left alone. Process identities
are checked again before TERM and KILL; termination has a 1.5-second grace period.
Lock files and cached packages are never deleted. Unavailable inspection tools
produce a diagnostic without adding a workflow failure. Hosted runners and local
invocations skip this recovery. `test-runner-preflight.yml` exercises real process
and lock recovery in private fixtures on both architectures without building PHP.

Normal PHP and extension cache jobs consume `conf/dependencies.json`. It pins
Homebrew core and selects the exact dependency bottles for each architecture.
An installed, healthy keg at the approved version can be reused; otherwise the
approved bottle is restored. A different runner compiler, SDK or installed
dependency recipe does not cause an approved build tool such as GCC to compile
again. PHP and extension targets can still compile when their own inputs change.
An unapproved dependency version or unavailable approved bottle stops with a
dependency-update instruction instead of silently upgrading or compiling it.

Run `update-dependencies.yml` on `main` to upgrade dependencies. Its optional
`homebrew-core-commit` input selects a specific revision; an empty input selects
current Homebrew core. The job prepares dependencies for all PHP variants,
coverage extensions, optional packs and archive tools on both baseline platforms.
It then clears the installed formulae on those CI runners, restores the proposed
set with zero source builds, checks native linkage, and verifies warm reuse.
Only matching successful proofs from both architectures can promote the new
snapshot. `publish=false` keeps the proposed snapshot as a workflow artifact.
Timing data and validation reports remain workflow artifacts. The previous
approved source bottles are protected while a replacement is prepared.

Dependency updates do not force a PHP rebuild. Subsequent normal cache jobs
compare their actual PHP, extension and runtime dependency inputs as usual.
The `organize-source-cache.yml` workflow inventories misplaced bottles, copies
and verifies their exact bytes, then removes the old copies and empty legacy
shard releases. It resumes verified copies and refuses cleanup while builds hold
claims. Run it with `apply=false` to inspect the plan before migration.
Migration writes are paced, and a GitHub quota response stops all workers with
the reset time in the log. Resume after that time; verified copies are reused.

Refresh an installer without rebuilding PHP or its dependencies:

```sh
gh workflow run mirror.yml -R shivammathur/php-darwin \
  -f php-version=8.4 -f publish-installers=true
```

R2 verification precedes the GitHub installer update. Installer-only changes
normally reuse published archives; recipe/dependency changes need cache builds.

## Installation and troubleshooting

Normal installs prefer GitHub Releases and fall back to Cloudflare, validating
the final checksum before extraction. `PHP_DARWIN_PREFER_MIRROR=true` explicitly
reverses that order and is used during cache construction. Do not change the
normal setup-php download priority or add retries without diagnosing the cause.
Downloads on both origins retry every transport or HTTP error, with at most
three attempts per origin and bounded backoff. Errors still fail after the limit;
archive retries retain full SHA validation before extraction.

Preserve existing PHP kegs, configuration, services and unrelated Homebrew state.
The archive must supply the default `bin/php` link. A writable Homebrew prefix is
required; ordinary installation into a user-owned prefix needs no sudo.
Passwordless sudo remains a prerequisite for setup-php. Its self-hosted path may
reuse installed PHP or invoke Homebrew; direct release tests establish cache
coverage separately.

Installation timings are informational and do not gate builds, compatibility,
recovery or publication. Performance benchmarks and optimization are separate
from packaging; direct release timings include bootstrap and archive downloads.
QA helpers record phases through `BASH_ENV` without
adding probes to production installers. `test.yml` has an `trace-install`
input for detailed diagnostics. `PHP_DARWIN_VERIFY_RUNTIME=true` also enables
runtime/extension probes during an installation.

Use the `workflow-performance` and per-build timing artifacts to separate runner
queueing, dependency fetching, source compilation and publication. Check cache
miss records, archive metadata and actual links.

## Optional extension archives

`cache-extensions.yml` restores published PHP caches and builds Imagick, MongoDB
and Memcached independently. It never compiles PHP or adds these libraries to
the PHP archives. `conf/extension-packs.json` defines the supported versions and
the modules belonging to each pack.

`update-extensions.yml` checks every configured PHP version every six hours,
dispatching all versions together within Actions matrix limits.
Its optional `after-run` input waits for a successful prerequisite before dispatching;
failed or cancelled prerequisites stop the follow-up. Unchanged packs are skipped;
changed packs reuse the source-bottle cache. Manual runs can select PHP versions,
extensions and build variants. Builds share one job per PHP version and architecture;
compatibility checks share one job per PHP version and runner, covering every
selected build variant and pack. A complete 14-version campaign uses 28 native
build jobs and 56 compatibility jobs instead of 336 and 280. Each passing pack
is checkpointed separately, even if another pack in its job fails. Native cache
campaigns run on dispatch or schedule; source changes run the local validation CI.
Publication requires native installation and
functional tests on the build platforms and newer macOS releases.
Each pack must load correctly and preserve PHP and services. Archives
are published to the separate `extensions` release and Cloudflare only after all
selected tests pass. Installer updates are published even when recipes are unchanged.
If publication fails after validation, run `publish-extensions.yml` with that run's
`run-id`. It checks every source build and compatibility job before publishing the
existing artifacts, without rebuilding PHP or extensions.
The source can also be a completed `recover-extensions.yml` run whose plan,
archive reuse, compatibility checks and exact publication selection passed.
This resumes its publisher without rerunning the Ubuntu recovery dependencies.
For an installer-only change, dispatch `publish-extensions.yml` with
`installer-only=true` and no `run-id`. This shares the publication lock and
updates only `install-extensions.cjs` at both origins; archives and manifests
remain unchanged. Validate the installer against existing native packs first.
If builds partly failed or the compatibility workflow needs a fix, run
`recover-extensions.yml` with the completed source `run-id`. It selects only
successful builds and pins their artifact IDs and archive hashes. Optionally set
`php-versions` to a space-separated list to recover only those versions, for
example when another version's PHP API changed after the source run. Omit it to
select all versions; unsupported, duplicate or unavailable selections fail.
A successful compatibility job is reused only when its checksum-verified reports match every
selected archive and confirm preservation with a valid timing report.
Only missing or failed groups run the current native checks. The recovery plan
artifact records reused evidence; publication waits for every remaining group.
Failed builds remain excluded and can be rebuilt separately. Missing or expired
artifacts stop recovery; rerunning failed recovery jobs preserves passing work.
Recovery API reads use the same bounded service-error policy as publication;
authentication failures and invalid responses stop immediately.
For an interrupted campaign, pass completed `resume-runs` to `cache-extensions.yml`
in oldest-to-newest order. The latest successful artifact for each pack wins.
Ubuntu jobs download exact artifact IDs, verify archive hashes and native reports,
and retain their bytes; Macs only build unpublished gaps and run compatibility.
Already published variants are retained when their PHP release/source commit still
matches. Normal runs without `resume-runs` apply full recipe freshness checks.
The planner logs why each pack needs rebuilding. PHP Darwin implementation changes
and repository revisions do not invalidate PHP, extension or dependency caches.
Historical builder hashes in published metadata are ignored. Dependency upgrades
remain explicit through `update-dependencies.yml`; a missing approved dependency
fails instead of compiling in an ordinary PHP cache job. Replacing unchanged
software versions requires an explicit cache repair.
This recovery path works for both architectures. Regular Homebrew ARM bottles
cannot replace debug/ZTS or development-PHP extension binaries; missing matching
binaries and Mach-O relocation/signing still require macOS.
Publication resumes by reusing GitHub assets with matching SHA256 digests and
Cloudflare objects whose downloaded bytes pass SHA256 verification. Existing
SHA-addressed archives use their ordinary cache URLs; mutable files and reads
after uploads use fresh queries to avoid stale manifests or cached missing responses.
Small archives use single-object uploads. Cloudflare publication reads have up to
three attempts with exponential backoff. Extension and source-bottle publishers
share a budget of twelve extra attempts per job; GitHub operations retain their
separate bounded policy. Extension rate-limit delays are capped at thirty seconds.
Immutable extension read retries resume only locally authenticated prefixes,
validate Content-Range, and check the complete SHA256 before publishing a manifest.
Actions artifact uploads and downloads also get at most three attempts, keeping
their original compression, retention and overwrite settings. Successful steps
are not repeated.
Transfer retries cover every error, including credential and certificate errors,
and stop after three attempts. AWS internal retries are disabled where the outer
loop owns recovery, preventing multiplied attempts. Validation is never bypassed.
Lost upload responses are reconciled with the remote object before another write.
Each version's manifest is committed only after all its selected archives are
verified. An exhausted failure leaves that version incomplete while independent
versions continue; the job still fails if any version remains incomplete.
Publication reports list completed, failed and
remaining versions, plus HTTP timing, received bytes and selected Cloudflare
headers for each verification read, including timeouts. They omit URLs and
credentials. Recover only the remaining versions after diagnosing failures.
Publication has a 30-minute limit. Healthy transfers do not wait or repeat work.
Nightly packs also track the PHP source commit, so a new nightly with the same
version string rebuilds its extension modules while reusing dependency bottles.

Each archive carries private runtime libraries, relocated Mach-O load paths,
licenses and module metadata. The standalone `scripts/installer/install-extensions.cjs`
prefetches requested packs concurrently, then installs only packs matching the
installed PHP API, architecture and build variant. Downloads prefer GitHub Releases
and fall back to Cloudflare. Downloaded packs are verified and extracted in private
temporary directories while PHP setup continues. PHP ABI checks, module loading,
private runtime placement and extension links wait until PHP is ready. No Homebrew
commands run in the extension installer.

### Passing optional extensions to the PHP installer

`install.sh VERSION BUILD THREAD_SAFETY [LOCAL_ARCHIVE] [EXTENSIONS]` accepts
the raw comma-separated extensions input in its fifth argument. The fourth
argument remains the optional local PHP archive; pass an empty string for a
normal release download. setup-php only forwards `INPUT_EXTENSIONS` at its
existing PHP cache call. It contains no pack selector, downloader or enabler.
Preinstalled PHP paths that do not call the cache installer retain setup-php's
normal extension handling.

The readable generated PHP installer embeds `install-extensions.cjs`. When Node
is available it selects unversioned optional packs, excluding explicit disabled,
versioned or source requests and conflicting serializer requests. Preparation
runs while PHP installs; installation waits for successful PHP verification and
requires matching release/source, ABI, architecture and build variant. Optional
failures leave the caller's existing extension fallback available. PHP-only
installation does not require Node or contact extension origins.

The installer enables pack modules and their serializers in an owned `conf.d`
file, without replacing user configuration. Private library/resource variables
are written to `GITHUB_ENV` for subsequent action steps. Standalone users can
source the printed private pack `environment.sh` path. No shell profiles or
services are modified. Optional downloads retry all errors on either origin with at most three attempts,
1/2-second backoff and capped Retry-After. Every promoted archive is SHA-verified.

### Workflow validation and runner maintenance

Full archive compatibility uses named macOS versions; `macos-latest` is exercised
separately by `test-homebrew.yml` with published PHP 8.5. That weekly/manual smoke
also checks `brew update`, outside every PHP publication's cold/hot install gate.
`brew config` and `brew doctor` run once after cleanup, before build/test work;
per-variant checks retain receipts, linkage, relinking, FPM and preservation.
The manual `test.yml` and normal architecture tests share the `test-cache` action,
including runner recovery, architecture validation and rollback diagnostics.

`validate.yml` and `test-runner-preflight.yml` run on main pushes and pull requests;
use workflow_dispatch to validate an un-PR branch. `test-source-lock.yml` exercises
live coordination once on Ubuntu. Source-cache native tests have scoped path
filters and still intentionally build isolated fixtures; do not dispatch that
workflow for a no-build validation request. Use existing published/archive inputs
for those requests. Timing and diagnostic upload failures do not block publication;
required archives, compatibility evidence and approval snapshots remain gates.
