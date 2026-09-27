#!/usr/bin/env bash

source_path=${1:?}
source_commit=${2:?}
repository=${3:?}
branch=${4:?}
destination=${5:?}

[ -d "$source_path/.git" ] || {
  printf 'Homebrew tap repository not found: %s\n' "$source_path" >&2
  exit 1
}
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'Invalid Homebrew tap commit: %s\n' "$source_commit" >&2
  exit 1
}
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$branch" != /* ]] && \
  [[ "$branch" != *..* ]] || {
  printf 'Invalid Homebrew tap branch: %s\n' "$branch" >&2
  exit 1
}
case "$repository" in https://github.com/*) ;; *)
  printf 'Invalid Homebrew tap repository: %s\n' "$repository" >&2
  exit 1
  ;;
esac
[ ! -e "$destination" ] && [ ! -L "$destination" ] || {
  printf 'Homebrew tap snapshot already exists: %s\n' "$destination" >&2
  exit 1
}

mkdir -p "$destination" || exit 1
git init -q -b "$branch" "$destination" || exit 1
git -C "$destination" remote add origin "$repository" || exit 1
git -C "$destination" fetch -q --depth=1 --no-tags "file://$source_path" "$source_commit" || exit 1
git -C "$destination" checkout -q -B "$branch" FETCH_HEAD || exit 1
git -C "$destination" update-ref "refs/remotes/origin/$branch" "$source_commit" || exit 1
git -C "$destination" config "branch.$branch.remote" origin || exit 1
git -C "$destination" config "branch.$branch.merge" "refs/heads/$branch" || exit 1
git -C "$destination" config php-darwin.snapshot-commit "$source_commit" || exit 1

[ "$(git -C "$destination" rev-parse HEAD)" = "$source_commit" ] || exit 1
[ "$(git -C "$destination" symbolic-ref --short HEAD)" = "$branch" ] || exit 1
[ "$(git -C "$destination" rev-parse --is-shallow-repository)" = true ] || exit 1
snapshot_status=$(git -C "$destination" status --porcelain) || exit 1
[ -z "$snapshot_status" ] || exit 1
