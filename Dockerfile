# ----------------------------
# Base PHP 8.4 image
# ----------------------------
FROM php:8.4-fpm

# ----------------------------
# Install dependencies
# ----------------------------
RUN apt-get update && apt-get install -y \
    git curl unzip zip libpng-dev libonig-dev libxml2-dev \
    libzip-dev libfreetype6-dev libjpeg62-turbo-dev libwebp-dev \
    nginx \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# Install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) gd pdo_mysql mbstring exif pcntl bcmath zip

WORKDIR /var/www/html

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Copy composer files and install (NO SCRIPTS)
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --optimize-autoloader --prefer-dist

# Copy app
COPY . .

# Run composer scripts
RUN composer dump-autoload --optimize \
    && php artisan package:discover --ansi

# NPM build
RUN npm ci --progress=false && npm run build
RUN npm prune --production && rm -rf node_modules/.cache /root/.npm

# Permissions
RUN chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R ug+rwx storage bootstrap/cache

# Fix PHP-FPM to listen on TCP (not socket) - more reliable
RUN sed -i 's|listen = /run/php/php.*-fpm.sock|listen = 127.0.0.1:9000|g' /usr/local/etc/php-fpm.d/www.conf || \
    echo "listen = 127.0.0.1:9000" >> /usr/local/etc/php-fpm.d/www.conf

# Nginx config - TCP fastcgi_pass
RUN echo 'server {
listen 0.0.0.0:8080;
server_name _;
root /var/www/html/public;
index index.php;

location / {
try_files $uri $uri/ /index.php?$query_string;
}

location ~ \.php$ {
try_files $uri =404;
fastcgi_pass 127.0.0.1:9000;
fastcgi_index index.php;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
include fastcgi_params;
}

location ~ /\. {
deny all;
}
}' > /etc/nginx/conf.d/default.conf

# Remove default nginx site
RUN rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

# Copy nginx config to proper location
RUN mv /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default

# Test nginx config
RUN nginx -t

EXPOSE 8080

# Start PHP-FPM in background, then nginx in foreground
CMD php-fpm -D && nginx -g "daemon off;"
