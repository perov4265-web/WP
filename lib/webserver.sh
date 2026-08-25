#!/usr/bin/env bash
# lib/webserver.sh — конфигурация Nginx или Apache для WordPress.
# shellcheck shell=bash

server_names() {
  if is_ip "$SITE_DOMAIN"; then printf '_'; else printf '%s www.%s' "$SITE_DOMAIN" "$SITE_DOMAIN"; fi
}

configure_webserver() {
  info "Настройка веб-сервера (${WEB_SERVER})"
  BODY_MAX="$(double_size "$UPLOAD_MAX")"
  case "$WEB_SERVER" in
    nginx)  configure_nginx ;;
    apache) configure_apache ;;
    *) die "Неизвестный веб-сервер: ${WEB_SERVER}" ;;
  esac
}

# --------------------------------------------------------------------- NGINX
configure_nginx() {
  local conf="/etc/nginx/sites-available/${SITE_DOMAIN}.conf"
  local pma_block=""

  if [[ "${INSTALL_PMA}" == "yes" ]]; then
    pma_block="$(cat <<'PMA'

    # ---- phpMyAdmin ----
    location ^~ /phpmyadmin/ {
        alias __PMA_DIR__/;
        index index.php;

        location ~ ^/phpmyadmin/(.+\.php)$ {
            alias __PMA_DIR__/$1;
            fastcgi_pass __FPM_PASS__;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $request_filename;
        }
        location ~* ^/phpmyadmin/(.+\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt|svg|woff|woff2|ttf))$ {
            alias __PMA_DIR__/$1;
        }
    }
    location = /phpmyadmin { return 301 /phpmyadmin/; }
PMA
)"
  fi

  cat > "$conf" <<'NGINX'
# Создано wp-autoinstall
server {
    listen 80;
    listen [::]:80;
    server_name __SERVER_NAMES__;

    root __WP_PATH__;
    index index.php index.html index.htm;

    client_max_body_size __BODY_MAX__;

    access_log /var/log/nginx/__DOMAIN__.access.log;
    error_log  /var/log/nginx/__DOMAIN__.error.log;

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { allow all; log_not_found off; access_log off; }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass __FPM_PASS__;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout __EXEC_TIME__;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        include fastcgi_params;
    }
__PMA_BLOCK__

    # Кэширование статики
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, max-age=2592000";
        access_log off;
        try_files $uri =404;
    }

    # Безопасность
    location ~* /(?:uploads|files)/.*\.php$ { deny all; }
    location ~ /\.(?!well-known).* { deny all; }
    location = /wp-config.php { deny all; }
    location = /xmlrpc.php { deny all; access_log off; log_not_found off; }
    location ~* ^/(?:wp-admin/includes|wp-includes/.*\.php)$ { deny all; }

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
NGINX

  # подстановка значений (чистый bash, без внешних зависимостей)
  local tpl names
  names="$(server_names)"
  tpl="$(cat "$conf")"
  tpl="${tpl//__PMA_BLOCK__/$pma_block}"   # блок phpMyAdmin вставляем первым:
  tpl="${tpl//__SERVER_NAMES__/$names}"   # внутри него тоже есть плейсхолдеры
  tpl="${tpl//__WP_PATH__/$WP_PATH}"
  tpl="${tpl//__BODY_MAX__/$BODY_MAX}"
  tpl="${tpl//__DOMAIN__/$SITE_DOMAIN}"
  tpl="${tpl//__FPM_PASS__/$PHP_FPM_PASS}"
  tpl="${tpl//__EXEC_TIME__/${MAX_EXEC_TIME:-300}}"
  tpl="${tpl//__PMA_DIR__/${PMA_DIR:-/usr/share/phpmyadmin}}"
  printf '%s\n' "$tpl" > "$conf"

  ln -sf "$conf" "/etc/nginx/sites-enabled/${SITE_DOMAIN}.conf"
  rm -f /etc/nginx/sites-enabled/default
  run nginx -t || { nginx -t; die "Ошибка в конфигурации Nginx (см. вывод выше)."; }
  svc_restart nginx
  ok "Конфигурация Nginx: ${conf}"
}

# -------------------------------------------------------------------- APACHE
configure_apache() {
  local conf="/etc/apache2/sites-available/${SITE_DOMAIN}.conf"
  local handler pma_block=""

  if [[ "$PHP_FPM_PASS" == unix:* ]]; then
    handler="proxy:unix:${PHP_FPM_LISTEN}|fcgi://localhost"
  else
    handler="proxy:fcgi://${PHP_FPM_LISTEN}"
  fi

  if [[ "${INSTALL_PMA}" == "yes" ]]; then
    pma_block="$(cat <<PMA

    Alias /phpmyadmin ${PMA_DIR:-/usr/share/phpmyadmin}
    <Directory ${PMA_DIR:-/usr/share/phpmyadmin}>
        Options -Indexes +FollowSymLinks
        DirectoryIndex index.php
        AllowOverride None
        Require all granted
    </Directory>
PMA
)"
  fi

  cat > "$conf" <<APACHE
# Создано wp-autoinstall
<VirtualHost *:80>
    ServerName ${SITE_DOMAIN}
$( is_ip "$SITE_DOMAIN" || printf '    ServerAlias www.%s' "$SITE_DOMAIN" )
    ServerAdmin ${WP_EMAIL}
    DocumentRoot ${WP_PATH}

    <Directory ${WP_PATH}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch \.php\$>
        SetHandler "${handler}"
    </FilesMatch>

    <Files wp-config.php>
        Require all denied
    </Files>
    <Files xmlrpc.php>
        Require all denied
    </Files>
    <DirectoryMatch "^${WP_PATH}/wp-content/uploads/.*\.php\$">
        Require all denied
    </DirectoryMatch>
${pma_block}

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"

    ErrorLog \${APACHE_LOG_DIR}/${SITE_DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${SITE_DOMAIN}-access.log combined
</VirtualHost>
APACHE

  step "Включение модулей Apache"
  run a2enmod proxy_fcgi setenvif rewrite headers expires || true
  run a2enconf "php${PHP_VER}-fpm" || true
  run a2ensite "${SITE_DOMAIN}.conf"
  run a2dissite 000-default.conf || true

  # .htaccess для постоянных ссылок
  if [[ ! -f "${WP_PATH}/.htaccess" ]]; then
    cat > "${WP_PATH}/.htaccess" <<'HTA'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HTA
    chown www-data:www-data "${WP_PATH}/.htaccess"
    chmod 644 "${WP_PATH}/.htaccess"
  fi

  run apache2ctl configtest || { apache2ctl configtest; die "Ошибка в конфигурации Apache."; }
  svc_restart apache2
  ok "Конфигурация Apache: ${conf}"
}
