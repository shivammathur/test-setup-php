#!/usr/bin/env bash
set -euo pipefail

# Resolve the same dependency recipes on every architecture and retry.
[[ "${HOMEBREW_CORE_COMMIT:?}" =~ ^[0-9a-f]{40}$ ]] || exit 1
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
brew tap --force homebrew/core
core=$(brew --repository homebrew/core)
bash "$(dirname "${BASH_SOURCE[0]}")/ensure-core-history.sh" "$core"
if ! git -C "$core" cat-file -e "$HOMEBREW_CORE_COMMIT^{commit}" 2>/dev/null; then
  # Keep full taps updateable: Homebrew refuses to update shallow core clones.
  git -C "$core" fetch --no-tags origin "$HOMEBREW_CORE_COMMIT"
fi
# Runner images and interrupted jobs can leave modified formulae in the tap.
# CI owns this checkout; local invocations must retain Git's dirty-tree guard.
checkout_flags=(--detach)
if [ "${GITHUB_ACTIONS:-}" = true ]; then checkout_flags+=(--force); fi
git -C "$core" checkout "${checkout_flags[@]}" "$HOMEBREW_CORE_COMMIT"
