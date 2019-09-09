xcode-select --install
/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
brew install wget
brew install openssl
brew install libxml2
brew link libxml2 --force
brew install jpeg
brew install libpng
brew install libmcrypt
cd /usr/local/src
wget https://downloads.php.net/~derick/php-7.4.0RC1.tar.gz
tar -xzvf php-7.4.0RC1.tar.gz
rm php-7.4.0RC1.tar.gz

cd /usr/local/src
cd php-7.4.0RC1

./configure \
  --prefix=/usr/local/dev/php-7.4.0RC1 \
  --with-config-file-path=/usr/local/dev/php-7.4.0RC1/etc \
  --with-config-file-scan-dir=/usr/local/php-7.4.0RC1/ext \
  --enable-bcmath \
  --enable-cli \
  --enable-mbstring \
  --enable-gd-jis-conv \
  --enable-sockets \
  --enable-exif \
  --enable-ftp \
  --enable-soap \
  --enable-zip \
  --enable-opcache \
  --enable-simplexml \
  --enable-maintainer-zts \
  --with-sqlite3 \
  --enable-xmlreader \
  --enable-xmlwriter \
  --with-mysql-sock=/tmp/mysql.sock \
  --with-mysqli=mysqlnd \
  --with-pdo-mysql=mysqlnd \
  --with-pdo-sqlite \
  --with-bz2 \
  --with-curl \
  --with-gd \
  --with-imap-ssl \
  --with-pear \  
  --with-openssl=/usr/local/Cellar/openssl/1.0.2j \
  --with-xmlrpc \
  --with-xsl \
  --with-zlib \
  --with-apxs2 \
  --with-iconv=/usr \
  --with-ldap
  
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
