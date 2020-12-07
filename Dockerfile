ARG PHP_VERSION=7.4

FROM wordpress:5.1-php${PHP_VERSION}

COPY --from=composer /usr/bin/composer /usr/bin/composer
RUN composer --version

# Node setup
RUN curl -sL https://deb.nodesource.com/setup_current.x | bash - \
  && apt-get install -yq nodejs build-essential

# Install npm
RUN npm install -g npm

# Install requirements for wp-cli support
RUN apt-get update \
  && apt-get install -y sudo less mariadb-client \
  && rm -rf /var/lib/apt/lists/*

# Install wp-cli
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
  && php wp-cli.phar --info \
  && chmod +x wp-cli.phar \
  && mv wp-cli.phar /usr/local/bin/wp

WORKDIR /usr/src/wordpress
