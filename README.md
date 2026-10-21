# Temporary runner pool

This branch provides disposable Ubuntu 22.04/24.04/26.04 x64/ARM64, macOS 14 ARM64,
macOS 15 Intel/ARM64, and macOS 26 ARM64 runners to a target
repository. Each host workflow job has a 360-minute timeout, accepts one target
job, and exits. An unassigned runner exits after 15 minutes. No artifacts or
caches are uploaded by the host workflow.

From an authenticated local checkout, launch a two-host trial with:

```sh
python3 scripts/dispatch_pool.py launch --host OWNER/HOST --target OWNER/TARGET --x64 1 --arm64 1
```

The default `linux` platform selects Ubuntu 24.04. For native compatibility
tests, select `--platform ubuntu-22.04`, `ubuntu-24.04`, or `ubuntu-26.04`;
the registered label and checked OS version must match. `ubuntu-latest` is an
x64-only option for planning/signing jobs, currently checked against 24.04.
If GitHub migrates that alias, the host check fails until the expected version
is reviewed and updated. Named Ubuntu images use Python 3.13 from the tool
cache, including Ubuntu 22.04 where the system Python lacks required APIs.

For jobs requesting `ubuntu-24-sf` or `ubuntu-24-arm-sf`, add
`--label-suffix sf` with `--platform ubuntu-24.04`. These hosts retain the
native Ubuntu 24.04 images and advertise only the suffixed OS label.

For five macOS 14 ARM64 hosts, use `--platform macos-14 --x64 0 --arm64 5`.
For macOS 15, use `--platform macos-15` and the desired architecture counts.
macOS 15 Intel hosts advertise `macos-15-intel`; ARM64 hosts advertise
`macos-14` or `macos-15` matching their real OS. No labels for a different OS
version are registered. macOS uses a Python runtime outside Homebrew so target cleanup
cannot remove the parent runner supervisor.

For target workflows requesting ARM-specific aliases, use `--platform
macos-15-arm64 --x64 0 --arm64 N` or `--platform macos-26-arm --x64 0 --arm64 N`.
These run on native `macos-15` and `macos-26` hosted images respectively.
The macOS 26 profile registers both `macos-26-arm` and `macos-26-arm64`.
Both profiles reject Intel and check the actual macOS major version.

The helper creates a unique environment restricted to this branch, saves the
target and per-runner JIT configurations as environment secrets, dispatches the batch,
and prints a local state path. After the host run completes, remove its secrets
and any idle registrations with `python3 scripts/dispatch_pool.py cleanup STATE`.
State files are private local files and contain no tokens.

Each `RUNNER_JIT_<ARCH>_<SLOT>` secret authorizes exactly one pre-registered
ephemeral runner. It cannot register additional runners. The target repository
is saved separately as `RUNNER_TARGET_REPOSITORY`. Administration credentials
remain on the dispatching machine.

Dispatch `runner-pool.yml` on `feature/ephemeral-runner-pool` with that environment
as `pool`, plus `platform`, `x64-count` and `arm64-count` (1–30 hosts in total). Use small
batches that can start promptly. Additional jobs require a new
batch of fresh hosts and JIT configurations. The target workflow must request the matching
host OS/architecture label.

The runner binary is pinned and SHA-256 verified. Registration output and runner
diagnostics remain on the disposable VM. Parent workflow credentials and file
command paths are excluded from the nested runner environment. Build secrets,
logs, and output policies come from the target workflow.

After completion, the cleanup helper deletes the batch environment and removes
offline runner IDs recorded in its local state. It refuses to remove active
runners. Normal ephemeral runners deregister automatically after their job.
Interrupted or unused registrations require this external cleanup.

The hosting account's Actions concurrency limits still apply. Use only for
trusted workflows in the target repository.
