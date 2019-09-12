sudo rm -rf /Library/Developer/CommandLineTools
sudo xcode-select --install
/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
brew install autoconf automake pcre libtool libpng webp jpeg oniguruma freetype libxml2 pkg-config krb5 openssl icu4c re2c bison libzip mcrypt zlib bzip2 enchant
brew link --force gettext
brew link --force bison
brew link --force openssl
brew link --force libxml2
brew link --force bzip2
echo 'export PATH="/usr/local/opt/bzip2/bin:$PATH"' >> ~/.bash_profile
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
export FFI_LIBS="-L/usr/local/opt/libffi/lib"
export FFI_CFLAGS="-I/usr/local/opt/libffi/include"
export ICU_LIBS="-L/usr/local/opt/icu4c/lib"
export ICU_CFLAGS="-I/usr/local/opt/icu4c/include"
export KERBEROS_LIBS="-L/usr/local/opt/krb5/lib"
export KERBEROS_CFLAGS="-I/usr/local/opt/krb5/include"
export OPENSSL_LIBS="-L/usr/local/opt/openssl@1.1/lib"
export OPENSSL_CFLAGS="-I/usr/local/opt/openssl@1.1/include"
export READLINE_LIBS="-L/usr/local/opt/readline/lib"
export READLINE_CFLAGS="-I/usr/local/opt/readline/include"
export BZIP2_LIBS="-L/usr/local/opt/bzip2/lib"
export BZIP2_CFLAGS="-I/usr/local/opt/bzip2/include"
export PKG_CONFIG_PATH="/usr/local/opt/krb5/lib/pkgconfig:/usr/local/opt/icu4c/lib/pkgconfig:/usr/local/obzip2pt/libffi/lib/pkgconfig:/usr/local/opt/openssl@1.1/lib/pkgconfig:/usr/local/opt/readline/lib/pkgconfig:/usr/local/opt/libxml2/lib/pkgconfig:/usr/local/opt/krb5/lib/pkgconfig:/usr/local/opt/icu4c/lib/pkgconfig:/usr/local/opt/libffi/lib/pkgconfig:/usr/local/opt/libxml2/lib/pkgconfig"
cd ~
curl -L -O https://github.com/phpbrew/phpbrew/raw/master/phpbrew
chmod +x ./phpbrew
./phpbrew init
./phpbrew install 7.4.0RC1 +default +bz2="$(brew --prefix bzip2)" +zlib="$(brew --prefix zlib)" -openssl --  --with-libxml
phpbrew switch php-7.4.0RC1
which php
php -v
brew install composer
composer -V
