FROM php:8.4-fpm

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git curl libpng-dev libonig-dev libxml2-dev \
    libzip-dev zip unzip nginx supervisor \
    && docker-php-ext-install pdo_mysql mbstring exif pcntl bcmath \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js 20 for assets
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g npm@latest

WORKDIR /var/www/html

# Composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Copy composer files first (cache layer)
COPY composer.json composer.lock ./

# Install PHP deps
RUN composer install --no-dev --no-scripts --optimize-autoloader --prefer-dist

# Copy app
COPY . .

# Copy composer scripts & run post scripts
RUN composer dump-autoload --optimize && composer run-script post-autoload-dump

# NPM assets
RUN npm ci --only=production && npm run build

# Laravel optimize
RUN php artisan config:cache \
    && php artisan route:cache \
    && php artisan view:cache

# Permissions
RUN chown -R www-data:www-data \
    storage bootstrap/cache \
    && chmod -R ug+rwx storage bootstrap/cache

# Nginx config (Laravel public routing)
COPY <<EOF /etc/nginx/conf.d/default.conf
server {
    listen ${PORT:-8080};
    server_name localhost;
    root /var/www/html/public;
    index index.php index.html;

    error_log /var/log/nginx/error.log;
    access_log /var/log/nginx/access.log;

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Supervisor config (Nginx + PHP-FPM)
COPY <<EOF /etc/supervisor/conf.d/supervisord.conf
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisord.log

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
stderr_logfile=/var/log/nginx/error.log
stdout_logfile=/var/log/nginx/access.log

[program:php-fpm]
command=php-fpm8.4 -F
autostart=true
autorestart=true
stderr_logfile=/var/log/php-fpm/error.log
stdout_logfile=/var/log/php-fpm/access.log
EOF

# Healthcheck
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8080}/ || exit 1

EXPOSE ${PORT:-8080}

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
