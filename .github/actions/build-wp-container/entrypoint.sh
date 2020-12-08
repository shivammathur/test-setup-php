#!/bin/sh -l

# Setup WordPress installation and add WooCommerce plugin
cd /var/www/public

pwd
wp --info
ls

wp config create --dbname=wordpress --dbuser=wordpress --dbpass=wordpress --dbhost=mysql --allow-root --debug
wp core install --url=http://localhost:8080 --title=Test --admin_user=wordpress --admin_password=wordpress --admin_email=admin@local.test --skip-email --allow-root
# wp plugin install woocommerce --activate --allow-root

# Prepare the plugin
cd /github/workspace

# Copy plugin from the workspace in the WordPress plugins folder and run everything from there
cp -R /github/workspace /var/www/public/wp-content/plugins/metagallery

cd /usr/src/wordpress/wp-content/plugins/metagallery

pwd
la -l
la -l /
la -l

# Install npm packages
# npm install
# npm run build
# npm run cy:run

# Setup Composer
# composer install --no-progress

# Run integration tests
# composer test:integration
