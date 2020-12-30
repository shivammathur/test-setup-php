setup_phpbuild() {
  (
    cd ~ || exit
    git clone git://github.com/php-build/php-build
    cd php-build || exit
    sudo ./install.sh
  )
  sudo cp .github/scripts/5.3 /usr/local/share/php-build/definitions/
  sudo cp .github/scripts/php-5.3.29-multi-sapi.patch /usr/local/share/php-build/patches/
  cp /usr/local/share/php-build/default_configure_options /usr/local/share/php-build/default_configure_options.bak
}

setup_pear() {
  sudo rm -rf "$install_dir"/bin/pear "$install_dir"/bin/pecl
  sudo curl -fsSL --retry "$tries" -o /usr/local/ssl/cert.pem https://curl.haxx.se/ca/cacert.pem
  sudo curl -fsSL --retry "$tries" -O https://github.com/pear/pearweb_phars/raw/v1.9.5/go-pear.phar
  sudo chmod a+x .github/scripts/install-pear.expect
  .github/scripts/install-pear.expect "$install_dir"
  rm go-pear.phar
  sudo "$install_dir"/bin/pear config-set php_ini "$install_dir"/etc/php.ini system
  sudo "$install_dir"/bin/pear channel-update pear.php.net
}

build_embed() {
  cp /usr/local/share/php-build/default_configure_options.bak /usr/local/share/php-build/default_configure_options
  sudo sed -i "/apxs2/d" /usr/local/share/php-build/default_configure_options
  sudo sed -i "/fpm/d" /usr/local/share/php-build/default_configure_options
  sudo sed -i "/cgi/d" /usr/local/share/php-build/default_configure_options
  echo "--enable-embed=shared" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
  build_php
  mv "$install_dir" "$install_dir-embed"
}

build_apache_fpm() {
  cp /usr/local/share/php-build/default_configure_options.bak /usr/local/share/php-build/default_configure_options
  sudo mkdir -p "$install_dir" "$install_dir"/"$(apxs -q SYSCONFDIR)"/mods-available /usr/local/ssl /var/lib/apache2
  sudo chmod -R 777 /usr/local/php /usr/local/ssl /usr/include/apache2 /usr/lib/apache2 /etc/apache2/ /var/lib/apache2 /var/log/apache2
  sudo sed -i "/cgi/d" /usr/local/share/php-build/default_configure_options
  echo "--with-apxs2=/usr/bin/apxs2" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
  echo "--enable-cgi" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
  echo "--enable-fpm" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
  echo "--with-fpm-user=www-data" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
  echo "--with-fpm-group=www-data" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
  build_php
  sudo ln -sv "$install_dir"/sbin/php-fpm "$install_dir"/bin/php-fpm
  sudo mkdir -p "$install_dir"/etc/systemd/system
  sudo sed -Ei "s|^listen = .*|listen = /run/php/php$PHP_VERSION-fpm.sock|" "$install_dir"/etc/php-fpm.conf
  sudo sed -Ei 's|;listen.owner.*|listen.owner = www-data|' "$install_dir"/etc/php-fpm.conf
  sudo sed -Ei 's|;listen.group.*|listen.group = www-data|' "$install_dir"/etc/php-fpm.conf
  sudo sed -Ei 's|;listen.mode.*|listen.mode = 0660|' "$install_dir"/etc/php-fpm.conf
  sudo sed -Ei "s|;pid.*|pid = /run/php/php$PHP_VERSION-fpm.pid|" "$install_dir"/etc/php-fpm.conf
  sudo sed -Ei "s|;error_log.*|error_log = /var/log/php$PHP_VERSION-fpm.log|" "$install_dir"/etc/php-fpm.conf
  sudo cp -fp .github/scripts/fpm.service "$install_dir"/etc/systemd/system/php-fpm.service
  sudo cp -fp .github/scripts/php-fpm-socket-helper "$install_dir"/bin/
  sudo chmod a+x "$install_dir"/bin/php-fpm-socket-helper
  sudo a2dismod php
  sudo mv /etc/apache2/mods-available/php.load /etc/apache2/mods-available/php"$PHP_VERSION".load
  sudo cp -fp /etc/apache2/mods-available/php"$PHP_VERSION".load "$install_dir"/etc/apache2/mods-available/
  sudo cp -fp .github/scripts/apache.conf /etc/apache2/mods-available/php"$PHP_VERSION".conf
  sudo cp -fp .github/scripts/apache.conf "$install_dir"/etc/apache2/mods-available/php"$PHP_VERSION".conf

  sudo mkdir -p /lib/systemd/system
  sudo cp -f "$install_dir"/etc/init.d/php-fpm /etc/init.d/php"$PHP_VERSION"-fpm
  sudo cp -f "$install_dir"/etc/systemd/system/php-fpm.service /lib/systemd/system/php"$PHP_VERSION"-fpm.service
  sudo service php"$PHP_VERSION"-fpm start
  mv "$install_dir" "$install_dir-fpm"
}

build_php() {
  if ! php-build -v -i production "$PHP_VERSION" "$install_dir"; then
    echo 'Failed to build PHP'
    exit 1
  fi
}

merge_sapi() {
  mv "$install_dir-fpm" "$install_dir"
  cp "$install_dir-embed/lib/libphp5.so" "$install_dir/lib/"
  cp -a "$install_dir-embed/include/php/sapi" "$install_dir/include/php"
}

configure_php() {
  sudo chmod 777 "$install_dir"/etc/php.ini
  (
    echo "date.timezone=UTC"
    echo "memory_limit=-1"
  ) >>"$install_dir"/etc/php.ini
  setup_pear
  sudo ln -sf "$install_dir"/bin/* /usr/bin/
  sudo ln -sf "$install_dir"/etc/php.ini /etc/php.ini
}

build_extensions() {
  chmod a+x .github/scripts/build_extensions.sh
  bash .github/scripts/build_extensions.sh
}

build_and_ship_package() {
  cd "$install_dir"/.. || exit
  tar -czf php53.tar.gz "$PHP_VERSION"
  curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -X DELETE https://api.bintray.com/content/"$BINTRAY_USER"/"$BINTRAY_REPO"/php53.tar.gz || true
  curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -T php53.tar.gz https://api.bintray.com/content/shivammathur/php/5.3-linux/5.3/php53.tar.gz || true
  curl --user "$BINTRAY_USER":"$BINTRAY_KEY" -X POST https://api.bintray.com/content/"$BINTRAY_USER"/"$BINTRAY_REPO"/5.3-linux/5.3/publish || true
}

install_dir=/usr/local/php/"$PHP_VERSION"
tries=10
sudo mkdir -p "$install_dir" /usr/local/ssl
sudo chmod -R 777 /usr/local/php /usr/local/ssl
setup_phpbuild
build_apache_fpm
build_embed
merge_sapi
configure_php
build_extensions
build_and_ship_package
