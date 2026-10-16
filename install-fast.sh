#!/usr/bin/env bash

set -euo pipefail

get() {
  local file_path=$1
  local link
  shift
  if [[ -n "${PHP5_CACHE_DIR:-}" ]]; then
    cp "$PHP5_CACHE_DIR/$cache" "$file_path"
    return
  fi
  for link in "$@"; do
    if curl -fsSL --retry 3 --compressed -o "$file_path" "$link"; then
      return
    fi
    echo "Failed to fetch $link"
  done
  return 1
}

setup_php() {
  cache="$php_version$arch_suffix-cache.tar.zst"
  get "$tmp_path.tar.zst" "$repo_url/releases/latest/download/$cache" "$cds/public/$repo/raw/files/$cache"
  # MacPorts archives mark most files as compressed. Do not recompress each
  # file with macOS filesystem compression while extracting the runtime.
  zstd -dcq "$tmp_path.tar.zst" | sudo tar --nopreserveHFSCompression -xf - -C /
  sudo mkdir -p "$usr_bin"
  sudo ln -sf "$opt_bin"/* "$usr_bin"
  sudo ln -sf "$opt_bin"/php-cgi"$version" "$usr_bin"/php-cgi
  sudo ln -sf "$opt_sbin"/php-fpm"$version" "$usr_bin"/php-fpm
}

add_imagick() {
  cache="$php_version-imagick$arch_suffix-cache.tar.zst"
  get "$tmp_path-imagick.tar.zst" "$repo_url/releases/latest/download/$cache" "$cds/public/$repo/raw/files/$cache"
  zstd -dcq "$tmp_path-imagick.tar.zst" | sudo tar --nopreserveHFSCompression -xf - -C /
}

configure_pecl() {
  sudo cp "$php_etc_dir"/.pearrc "$HOME/.pearrc"
  sudo chown "$(id -u):$(id -g)" "$HOME/.pearrc"
}

version=${1:-}
case "$version" in
  53|54|55) ;;
  *) echo "Usage: $0 <53|54|55> [imagick]" >&2; exit 1 ;;
esac
php_version="php$version"
php_etc_dir="/opt/local/etc/$php_version"
tmp_dir=$(mktemp -d)
trap 'sudo rm -rf "$tmp_dir"' EXIT
tmp_path="$tmp_dir/$php_version"
opt_bin="/opt/local/bin"
opt_sbin="/opt/local/sbin"
usr_bin="/usr/local/bin"
github="https://github.com"
cds="https://dl.cloudsmith.io"
repo="shivammathur/php5-darwin"
repo_url="$github/$repo"

case "$(uname -m)" in
  arm64) arch_suffix=-arm64 ;;
  x86_64) arch_suffix= ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

export TERM=xterm

if [ "${2:-}" = "imagick" ]; then
  add_imagick
else
  setup_php
  configure_pecl
fi
