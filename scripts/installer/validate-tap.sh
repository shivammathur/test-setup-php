#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

tap_path=${1:?}
version=${2:?}
expected_hash=${3:-}
repository=${4:?}
expected_commit=${5:-}
expected_branch=${6:-}
require_clean=${7:-false}

php_darwin_is_git_worktree "$tap_path" || {
  printf 'Homebrew tap is not a Git repository: %s\n' "$tap_path" >&2
  exit 1
}
actual_repository=$(git -C "$tap_path" remote get-url origin) || {
  printf 'Could not resolve the Homebrew tap origin\n' >&2
  exit 1
}
actual_repository=${actual_repository%.git}
[ "$actual_repository" = "${repository%.git}" ] || {
  printf 'Homebrew tap origin mismatch: %s\n' "$actual_repository" >&2
  exit 1
}
if [ -n "$expected_commit" ]; then
  actual_commit=$(git -C "$tap_path" rev-parse HEAD) || {
    printf 'Could not resolve the Homebrew tap commit\n' >&2
    exit 1
  }
  [ "$actual_commit" = "$expected_commit" ] || {
    printf 'Homebrew tap commit mismatch: %s\n' "$actual_commit" >&2
    exit 1
  }
fi
if [ -n "$expected_branch" ]; then
  actual_branch=$(git -C "$tap_path" symbolic-ref --short HEAD) || {
    printf 'Could not resolve the Homebrew tap branch\n' >&2
    exit 1
  }
  [ "$actual_branch" = "$expected_branch" ] || {
    printf 'Homebrew tap branch mismatch: %s\n' "$actual_branch" >&2
    exit 1
  }
  remote_commit=$(git -C "$tap_path" rev-parse "refs/remotes/origin/$expected_branch") || {
    printf 'Could not resolve the Homebrew tap remote branch\n' >&2
    exit 1
  }
  [ "$remote_commit" = "$expected_commit" ] || {
    printf 'Homebrew tap remote branch does not match its snapshot commit\n' >&2
    exit 1
  }
fi
if [ -n "$expected_hash" ]; then
  actual_hash=$(HOMEBREW_PHP_PATH="$tap_path" bash "$script_dir/../lib/source-hash.sh" "$version") || {
    printf 'Could not hash the Homebrew tap formulae\n' >&2
    exit 1
  }
  [ "$actual_hash" = "$expected_hash" ] || {
    printf 'Homebrew tap formula hash mismatch\n' >&2
    exit 1
  }
fi
if [ -n "$expected_branch" ] || [ -n "$expected_hash" ] || [ "$require_clean" = true ]; then
  tap_status=$(git -C "$tap_path" status --porcelain --untracked-files=all) || {
    printf 'Could not inspect Homebrew tap status\n' >&2
    exit 1
  }
  [ -z "$tap_status" ] || {
    printf 'Homebrew tap snapshot has changed or untracked files\n' >&2
    exit 1
  }
fi
[ -z "$expected_hash" ] || printf '%s\n' "$actual_hash"
