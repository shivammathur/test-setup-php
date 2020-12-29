setup_phpbuild() {
  (
    cd ~ || exit
    git clone git://github.com/php-build/php-build
    cd php-build || exit
    sudo ./install.sh
  )
  sudo cp .github/scripts/5.3 /usr/local/share/php-build/definitions/
  if [ "$TYPE" = "cgi" ]; then
    sudo sed -i "/fpm/d" /usr/local/share/php-build/default_configure_options
    echo "--enable-cgi" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
  elif [ "$TYPE" = "fpm" ]; then
    sudo sed -i "/cgi/d" /usr/local/share/php-build/default_configure_options
    echo '"--with-apxs2" "/usr/bin/apxs2"' | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
    echo "--enable-fpm" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
    echo "--with-fpm-user=www-data" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
    echo "--with-fpm-group=www-data" | sudo tee -a /usr/local/share/php-build/default_configure_options >/dev/null 2>&1
  fi
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

configure_php_fpm() {
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
}

build_php() {
  if ! php-build -v -i production "$PHP_VERSION" "$install_dir"; then
    echo 'Failed to build PHP'
    exit 1
  fi

  sudo chmod 777 "$install_dir"/etc/php.ini
  (
    echo "date.timezone=UTC"
    echo "memory_limit=-1"
  ) >>"$install_dir"/etc/php.ini
  setup_pear
  sudo ln -sf "$install_dir"/bin/* /usr/bin/
  sudo ln -sf "$install_dir"/etc/php.ini /etc/php.ini
  if [ "$TYPE" = "fpm" ]; then
    configure_php_fpm
  fi
}

install_dir=/usr/local/php/"$PHP_VERSION"
tries=10
sudo mkdir -p "$install_dir" /usr/local/ssl
sudo chmod -R 777 /usr/local/php /usr/local/ssl
setup_phpbuild
build_php
ls -la "$install_dir"/bin
