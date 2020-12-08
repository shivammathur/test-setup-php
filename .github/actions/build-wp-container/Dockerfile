ARG PHP_VERSION=7.4
ARG WP_VERSION=5.5

FROM wordpress:${WP_VERSION}-php${PHP_VERSION}

COPY --from=composer /usr/bin/composer /usr/bin/composer
RUN composer --version

# Node setup
RUN curl -sL https://deb.nodesource.com/setup_current.x | bash - \
  && apt-get install -yq nodejs build-essential

# Install npm
# RUN npm install -g npm

# Install requirements for wp-cli support
RUN apt-get update \
  && apt-get install -y sudo less mariadb-client \
  && rm -rf /var/lib/apt/lists/*

# Install wp-cli
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
  && php wp-cli.phar --info \
  && chmod +x wp-cli.phar \
  && mv wp-cli.phar /usr/local/bin/wp

# Install Cypress
RUN apt-get update && apt-get install -y \
    libgtk2.0-0 libgtk-3-0 libgbm-dev libnotify-dev libgconf-2-4 \
    libnss3 libxss1 libasound2 libxtst6 xauth xvfb

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /var/www/public

ENTRYPOINT ["/entrypoint.sh"]
