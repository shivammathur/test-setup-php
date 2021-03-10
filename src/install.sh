#!/usr/bin/env bash

get() {
  file_path=$1
  shift
  links=("$@")
  for link in "${links[@]}"; do
    status_code=$(sudo curl -w "%{http_code}" -o "$file_path" -sL "$link")
    [ "$status_code" = "200" ] && break
  done
}

install() {
  sudo mkdir -p /tmp/php
  get /tmp/"$tar_file" "https://github.com/shivammathur/php-ubuntu/releases/latest/download/$tar_file" "https://dl.cloudsmith.io/public/shivammathur/php-ubuntu/raw/files/$tar_file"
  sudo tar -I zstd -xf /tmp/"$tar_file" -C /
}

. /etc/lsb-release
version=$1
tar_file=php_"$version"%2Bubuntu"$DISTRIB_RELEASE".tar.zst
install
