#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/lib.sh
. "$script_dir/../lib/lib.sh"

tap_path=${1:?}
cached_tap_path=${2:?}
version=${3:?}
expected_hash=${4:?}
repository=${5:?}
cached_commit=${6:?}
expected_branch=${7:?}

bash "$script_dir/validate-tap.sh" "$tap_path" "$version" '' "$repository" \
  >/dev/null || exit 1
actual_hash=$(HOMEBREW_PHP_PATH="$tap_path" bash "$script_dir/../lib/source-hash.sh" "$version" 2>/dev/null) || \
  actual_hash=
formula_status=$(git -C "$tap_path" status --porcelain --untracked-files=all -- Formula 2>/dev/null) || {
  printf 'Could not inspect Homebrew tap formula status\n' >&2
  exit 1
}
formula_status=$(awk 'substr($0, 1, 3) == "?? " && $0 ~ /(^|\/)\.DS_Store$/ { next } { print }' \
  <<< "$formula_status") || {
  printf 'Could not filter Homebrew tap formula status\n' >&2
  exit 1
}
if [ "$actual_hash" = "$expected_hash" ] && [ -z "$formula_status" ]; then
  printf 'keep\n'
  exit 0
fi

if ! git -C "$tap_path" diff --quiet -- . || ! git -C "$tap_path" diff --cached --quiet -- .; then
  printf 'Remove changes from %s or untap %s before retrying the cache install\n' "$tap_path" \
    "$(php_darwin_package_config tap)" >&2
  exit 1
fi
untracked_paths=$(git -C "$tap_path" ls-files --others --exclude-standard) || {
  printf 'Could not inspect untracked Homebrew tap files\n' >&2
  exit 1
}
untracked_path=
while IFS= read -r candidate_path; do
  case "$candidate_path" in .DS_Store|*/.DS_Store) ;; *) untracked_path=$candidate_path; break ;; esac
done <<< "$untracked_paths"
[ -z "$untracked_path" ] || {
  printf 'Remove changes from %s or untap %s before retrying the cache install\n' "$tap_path" \
    "$(php_darwin_package_config tap)" >&2
  exit 1
}
existing_commit=$(git -C "$tap_path" rev-parse HEAD) || {
  printf 'Could not resolve the installed Homebrew tap commit\n' >&2
  exit 1
}
actual_cached_commit=$(git -C "$cached_tap_path" rev-parse HEAD) || {
  printf 'Could not resolve the cached Homebrew tap commit\n' >&2
  exit 1
}
[ "$actual_cached_commit" = "$cached_commit" ] || {
  printf 'Cached Homebrew tap commit does not match the archive metadata\n' >&2
  exit 1
}
snapshot_commit=$(git -C "$tap_path" config --get php-darwin.snapshot-commit 2>/dev/null) || \
  snapshot_commit=
if [ -z "$snapshot_commit" ] || [ "$snapshot_commit" != "$existing_commit" ]; then
  existing_branch=$(git -C "$tap_path" symbolic-ref --short HEAD 2>/dev/null) || {
    printf 'Homebrew tap formula hash mismatch on a detached checkout; run brew untap %s before retrying\n' \
      "$(php_darwin_package_config tap)" >&2
    exit 1
  }
  remote_commit=$(git -C "$tap_path" rev-parse "refs/remotes/origin/$expected_branch" 2>/dev/null) || {
    printf 'Homebrew tap formula hash mismatch without an origin/%s reference; run brew untap %s before retrying\n' \
      "$expected_branch" "$(php_darwin_package_config tap)" >&2
    exit 1
  }
  standard_checkout=false
  if [ "$existing_branch" = "$expected_branch" ]; then
    if [ "$remote_commit" = "$existing_commit" ] || \
      git -C "$tap_path" merge-base --is-ancestor "$existing_commit" "$remote_commit" 2>/dev/null; then
      standard_checkout=true
    fi
  fi
  [ "$standard_checkout" = true ] || {
    printf 'Homebrew tap has local commits or a nonstandard branch; run brew untap %s before retrying\n' \
      "$(php_darwin_package_config tap)" >&2
    exit 1
  }
  if [ -n "$snapshot_commit" ]; then
    printf 'Homebrew updated the cached tap; preserving it and using the requested snapshot temporarily\n' >&2
  fi
  printf 'temporary\n'
  exit 0
fi
[ "$existing_commit" != "$cached_commit" ] || {
  printf 'Homebrew tap source hash differs at the same cache snapshot commit\n' >&2
  exit 1
}

# Both snapshots are already present locally. Never make a network request to
# order them: shallow histories may be incomplete, in which case preserve the
# installed tap and use the requested snapshot only for this transaction.
if git -C "$cached_tap_path" merge-base --is-ancestor "$existing_commit" "$cached_commit" 2>/dev/null || \
  git -C "$tap_path" merge-base --is-ancestor "$existing_commit" "$cached_commit" 2>/dev/null; then
  printf 'replace\n'
else
  printf 'temporary\n'
fi
