release=$(lsb_release -r -s)
install_dir=~/php/"$PHP_VERSION"
action_dir=$(pwd)
sudo mkdir -p ~/php
sudo chmod -R 777 ~/php
(
  cd ~ || exit
  git clone git://github.com/php-build/php-build
  cd php-build || exit
  sudo ./install.sh
  sudo cp -rf "$action_dir"/.github/scripts/master /usr/local/share/php-build/definitions/master
)
php-build -v -i production master "$install_dir"
sudo chmod 777 "$install_dir"/etc/php.ini
(
  echo "date.timezone=UTC"
  echo "opcache.jit_buffer_size=256M"
  echo "opcache.jit=1235"
  echo "pcre.jit=1"
) >>"$install_dir"/etc/php.ini
sudo mkdir -p /usr/local/ssl
sudo wget -O /usr/local/ssl/cert.pem https://curl.haxx.se/ca/cacert.pem
curl -fsSL --retry 20 -O https://pear.php.net/go-pear.phar
sudo chmod a+x ./.github/scripts/install-pear.sh
./.github/scripts/install-pear.sh "$install_dir"
rm go-pear.phar
sudo "$install_dir"/bin/pear config-set php_ini "$install_dir"/etc/php.ini system
sudo "$install_dir"/bin/pear config-set auto_discover 1
sudo "$install_dir"/bin/pear channel-update pear.php.net
sudo ln -sv "$install_dir"/sbin/php-fpm "$install_dir"/bin/php-fpm
sudo ln -sf "$install_dir"/bin/* /usr/bin/
sudo ln -sf "$install_dir"/etc/php.ini /etc/php.ini
