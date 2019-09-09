sudo rm -rf /Library/Developer/CommandLineTools
sudo xcode-select --install
echo $PKG_CONFIG_PATH
/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
brew install autoconf automake libtool libxml2 pkg-config krb5 openssl icu4c re2c bison libzip mcrypt bzip2 enchant
brew link libxml2 --force
echo 'export PATH="/usr/local/opt/openssl@1.1/bin:$PATH"' >> ~/.bash_profile
echo 'export PATH="/usr/local/opt/krb5/bin:$PATH"' >> ~/.bash_profile
echo 'export PATH="/usr/local/opt/krb5/sbin:$PATH"' >> ~/.bash_profile
echo 'export PATH="/usr/local/opt/icu4c/bin:$PATH"' >> ~/.bash_profile
echo 'export PATH="/usr/local/opt/icu4c/sbin:$PATH"' >> ~/.bash_profile
echo 'export PATH="/usr/local/opt/bzip2/bin:$PATH"' >> ~/.bash_profile
echo 'export PATH="/usr/local/opt/bison/bin:$PATH"' >> ~/.bash_profile
echo 'export PATH="/usr/local/opt/libxml2/bin:$PATH"' >> ~/.bash_profile
source ~/.bash_profile
export LIBXML_LIBS="-L/usr/local/opt/libxml2/lib"
export LIBXML_CFLAGS="-I/usr/local/opt/libxml2/include"
export ENCHANT_LIBS="-L/usr/local/opt/enchant/lib"
export ENCHANT_CFLAGS="-I/usr/local/opt/enchant/include"
export LIBFFI_LIBS="-L/usr/local/opt/libffi/lib"
export LIBFFI_CFLAGS="-I/usr/local/opt/libffi/include"
export KERBEROS_LIBS="-L/usr/local/opt/krb5/lib"
export KERBEROS_CFLAGS="-I/usr/local/opt/krb5/include"
export OPENSSL_LIBS="-L/usr/local/opt/openssl@1.1/lib"
export OPENSSL_CFLAGS="-I/usr/local/opt/openssl@1.1/include"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib"
mkdir -p ~/local/php
cd ~/local/php
wget –quiet https://downloads.php.net/~derick/php-7.4.0RC1.tar.gz
tar -xzf php-7.4.0RC1.tar.gz
rm php-7.4.0RC1.tar.gz
cd ~/local/php
cd php-7.4.0RC1
uname -a
sudo ./buildconf --force
sudo ./configure --help
sudo ./configure \
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
--with-openssl \
--with-gmp \
--enable-bcmath \
--enable-calendar \
--enable-ftp \
--enable-sysvmsg \
--with-ffi \
--enable-zend-test=shared \
--enable-werror \
--with-pear 

make
make install

  
export LDFLAGS=-L/usr/local/opt/openssl/lib
export CPPFLAGS=-I/usr/local/opt/openssl/include

sudo make -j4
sudo make install

sudo ln -s ~/local/php/php-7.4.0RC1 /usr/local/php
sudo cp ~/local/php/php-7.4.0RC1/php.ini-production /etc/php.ini
which php
php -v
brew install composer
composer -V
