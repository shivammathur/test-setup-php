ARG PHP_VERSION=7.4

FROM php:${PHP_VERSION}-cli-alpine

COPY --from=composer /usr/bin/composer /usr/bin/composer
RUN composer --version

# Node setup
# ENV NODE_VERSION=8.10.0
# RUN apt-get install wget -y
# RUN wget -qO- https://raw.githubusercontent.com/creationix/nvm/v0.33.2/install.sh | bash
# ENV NVM_DIR=/root/.nvm
# RUN . "$NVM_DIR/nvm.sh" && nvm install ${NODE_VERSION}
# RUN . "$NVM_DIR/nvm.sh" &&  nvm use v${NODE_VERSION}
# RUN . "$NVM_DIR/nvm.sh" && nvm alias default v${NODE_VERSION}
# RUN cp /root/.nvm/versions/node/v${NODE_VERSION}/bin/node /usr/bin/
# RUN cp /root/.nvm/versions/node/v${NODE_VERSION}/bin/npm /usr/bin/
# RUN /root/.nvm/versions/node/v${NODE_VERSION}/bin/npm install  leasot@latest -g

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
