xcode-select --install
/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
brew install autoconf automake libtool
mkdir -p ~/local/php
cd ~/local/php
wget –quiet https://downloads.php.net/~derick/php-7.4.0RC1.tar.gz
tar -xzf php-7.4.0RC1.tar.gz
rm php-7.4.0RC1.tar.gz
cd ~/local/php
cd php-7.4.0RC1
uname -a
./buildconf --force
./configure \
--enable-option-checking=fatal \
--prefix="$HOME"/php-install \
--quiet \
--enable-phpdbg \
--enable-fpm \
--with-pdo-mysql=mysqlnd \
--with-mysqli=mysqlnd \
--with-pgsql \
--with-pdo-pgsql \
--with-pdo-sqlite \
--enable-intl \
--without-pear \
--enable-gd \
--with-jpeg \
--with-webp \
--with-freetype \
--with-xpm \
--enable-exif \
--with-zip \
--enable-soap \
--enable-xmlreader \
--with-xsl \
--with-tidy \
--with-xmlrpc \
--enable-sysvsem \
--enable-sysvshm \
--enable-shmop \
--enable-pcntl \
--with-readline \
--enable-mbstring \
--with-curl \
--with-gettext \
--enable-sockets \
--with-bz2 \
--with-openssl \
--with-gmp \
--enable-bcmath \
--enable-calendar \
--enable-ftp \
--with-pspell=/usr \
--with-enchant=/usr \
--with-kerberos \
--enable-sysvmsg \
--with-ffi \
--enable-zend-test=shared \
--enable-werror \
--with-pear 

make
make install

  
export LDFLAGS=-L/usr/local/opt/openssl/lib
export CPPFLAGS=-I/usr/local/opt/openssl/include

make -j4
make test
sudo make install

ln -s /usr/local/dev/php-7.4.0RC1 /usr/local/php

sudo cp /usr/local/src/php-7.4.0RC1/php.ini-production /usr/local/php/etc/php.ini
/usr/local/php/bin/pecl config-set php_ini /usr/local/php/etc/php.ini
/usr/local/php/bin/pear config-set php_ini /usr/local/php/etc/php.ini

php -v
brew install composer
composer -V
