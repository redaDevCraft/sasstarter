# ----------------------------
# Base PHP 8.4 image
# ----------------------------
FROM php:8.4-fpm

# ----------------------------
# Install system dependencies
# ----------------------------
RUN apt-get update && apt-get install -y \
    git curl unzip zip libpng-dev libonig-dev libxml2-dev \
    libzip-dev libfreetype6-dev libjpeg62-turbo-dev libwebp-dev \
    nginx supervisor \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# ----------------------------
# Install PHP extensions
# ----------------------------
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j$(nproc) gd pdo_mysql mbstring exif pcntl bcmath zip

# ----------------------------
# Set working directory
# ----------------------------
WORKDIR /var/www/html

# ----------------------------
# Install Composer
# ----------------------------
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# ----------------------------
# Copy composer files and install (NO SCRIPTS)
# ----------------------------
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --optimize-autoloader --prefer-dist

# ----------------------------
# Copy the rest of the app
# ----------------------------
COPY . .

# ----------------------------
# Run composer scripts
# ----------------------------
RUN composer dump-autoload --optimize \
    && php artisan package:discover --ansi

# ----------------------------
# Install Node dependencies and build assets
# ----------------------------
RUN npm ci --progress=false && npm run build
RUN npm prune --production && rm -rf node_modules/.cache /root/.npm

# ----------------------------
# Set permissions
# ----------------------------
RUN chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R ug+rwx storage bootstrap/cache

# ----------------------------
# Nginx config - bind to 0.0.0.0:8080
# ----------------------------
COPY <<EOF /etc/nginx/conf.d/default.conf
server {
    listen 0.0.0.0:8080;
    server_name _;
    root /var/www/html/public;
    index index.php;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        include fastcgi_params;
    }

    location ~ /\. {
        deny all;
    }
}
EOF

# ----------------------------
# Supervisor config
# ----------------------------
COPY <<EOF /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root

[program:php-fpm]
command=php-fpm -F
autostart=true
autorestart=true

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
EOF

# ----------------------------
# Startup script (opens port first, then migrates)
# ----------------------------
COPY <<EOF /start.sh
#!/bin/sh
echo "Starting web server..."
/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf &

# Wait for nginx to start listening
sleep 3

echo "Running migrations..."
php artisan migrate --force

# Keep container running
wait
EOF

RUN chmod +x /start.sh

# ----------------------------
# Expose port
# ----------------------------
EXPOSE 8080

# ----------------------------
# Start (server first, then migrations)
# ----------------------------
CMD ["/start.sh"]
