sudo rm -rf /Library/Developer/CommandLineTools
xcode-select --install
sudo xcode-select --switch /Library/Developer/CommandLineTools
/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
brew install autoconf automake libtool libxml2 pkg-config krb5 openssl icu4c re2c bison libzip mcrypt bzip2
brew link libxml2 --force
export LIBXML_LIBS="-L/usr/local/opt/libxml2/lib"
export LIBXML_CFLAGS="-I/usr/local/opt/libxml2/include"
export PKG_CONFIG_PATH="/usr/local/opt/libxml2/lib/pkgconfig"
export KERBEROS_LIBS="-L/usr/local/opt/krb5/lib"
export KERBEROS_CFLAGS="-I/usr/local/opt/krb5/include"
export OPENSSL_LIBS="-L/usr/local/opt/openssl@1.1/lib"
export OPENSSL_CFLAGS="-I/usr/local/opt/openssl@1.1/include"
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

sudo ln -s ~/local/php/php-7.4.0RC1 /usr/local/php
sudo cp ~/local/php/php-7.4.0RC1/php.ini-production /usr/local/php/etc/php.ini
php -i
php -v
brew install composer
composer -V
