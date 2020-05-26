LOG() {
  time=$(date '+%Y-%m-%d %H:%M:%S')
  echo "$time"" > ""$1" >>build.log
}

setup-phpbuild() {
  (
    cd ~ || exit
    git clone git://github.com/php-build/php-build
    cd php-build || exit
    sudo ./install.sh
    sudo cp -rf "$action_dir"/.github/scripts/master /usr/local/share/php-build/definitions/master
  )
}

build-php() {
  php-build -i production master "$install_dir"
  sudo chmod 777 "$install_dir"/etc/php.ini
  (
    echo "date.timezone=UTC"
    echo "opcache.jit_buffer_size=256M"
    echo "opcache.jit=1235"
    echo "pcre.jit=1"
  ) >>"$install_dir"/etc/php.ini
  sudo ln -sv "$install_dir"/sbin/php-fpm "$install_dir"/bin/php-fpm
  sudo ln -sf "$install_dir"/bin/* /usr/bin/
  sudo ln -sf "$install_dir"/etc/php.ini /etc/php.ini
}

setup-pear() {
  sudo curl -fsSL --retry "$tries" -o /usr/local/ssl/cert.pem https://curl.haxx.se/ca/cacert.pem
  sudo curl -fsSL --retry "$tries" -O https://pear.php.net/go-pear.phar
  sudo chmod a+x .github/scripts/install-pear.expect
  .github/scripts/install-pear.expect "$install_dir"
  rm go-pear.phar
  sudo "$install_dir"/bin/pear config-set php_ini "$install_dir"/etc/php.ini system
  sudo "$install_dir"/bin/pear channel-update pear.php.net
  sudo pecl install -f pcov
}

bintray-create-package() {
  curl \
  --user "$BINTRAY_USER":"$BINTRAY_KEY" \
  --header "Content-Type: application/json" \
  --data " \
{\"name\": \"$PHP_VERSION-linux\", \
\"vcs_url\": \"$GITHUB_REPOSITORY\", \
\"licenses\": [\"MIT\"], \
\"public_download_numbers\": true, \
\"public_stats\": true \
}" \
  https://api.bintray.com/packages/"$BINTRAY_USER"/"$BINTRAY_REPO" || true
}

build-and-ship() {
  (
    cd "$install_dir"/.. || exit
    sudo XZ_OPT=-e9 tar cfJ php_"$PHP_VERSION"+ubuntu"$release".tar.xz "$PHP_VERSION"
    curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -X DELETE https://api.bintray.com/content/"$BINTRAY_USER"/"$BINTRAY_REPO"/php_"$PHP_VERSION"+ubuntu"$release".tar.xz || true
    curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -T php_"$PHP_VERSION"+ubuntu"$release".tar.xz https://api.bintray.com/content/shivammathur/php/"$PHP_VERSION"-linux/"$PHP_VERSION"+ubuntu"$release"/php_"$PHP_VERSION"+ubuntu"$release".tar.xz || true
    curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -X POST https://api.bintray.com/content/"$BINTRAY_USER"/"$BINTRAY_REPO"/"$PHP_VERSION"-linux/"$PHP_VERSION"+ubuntu"$release"/publish || true
  )
}

push-log() {
  git config --local user.email "$GITHUB_EMAIL"
  git config --local user.name "$GITHUB_NAME"
  LOG "ubuntu$release build updated"
  git add .
  git commit -m "ubuntu$release build updated"
  for try in $(seq "$tries"); do
    echo "try: $try" >/dev/null
    git fetch && git rebase origin/master
    if git push -f https://"$GITHUB_USER":"$GITHUB_TOKEN"@github.com/"$GITHUB_REPOSITORY".git HEAD:master --follow-tags; then
      break
    else
      sleep 3s
    fi
  done
}

release=$(lsb_release -r -s)
install_dir=~/php/"$PHP_VERSION"
action_dir=$(pwd)
tries=10
sudo mkdir -m777 -p ~/php /usr/local/ssl
setup-phpbuild
build-php
setup-pear
bintray-create-package
build-and-ship
#push-log
