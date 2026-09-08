#!/usr/bin/env bash
# lib/webserver.sh — конфигурация Nginx или Apache для WordPress.
# shellcheck shell=bash

server_names() {
  if is_ip "$SITE_DOMAIN"; then printf '_'; else printf '%s www.%s' "$SITE_DOMAIN" "$SITE_DOMAIN"; fi
}

# Общие для всех сайтов настройки nginx: формат лога со временем ответа,
# лимит на запросы поиска и (по желанию) зона кэша страниц.
# shellcheck disable=SC2016  # $-переменные внутри строк принадлежат nginx, а не bash
nginx_global_snippet() {
  local f="/etc/nginx/conf.d/00-wp-autoinstall.conf"

  # log_format нельзя объявлять дважды. Но искать нужно во всех файлах, КРОМЕ
  # своего собственного: иначе при установке второго сайта мы находим строку в
  # старой версии этого же файла, решаем «уже есть» и затираем её при перезаписи —
  # а vhost первого сайта на неё ссылается, и nginx перестаёт стартовать.
  local have_format=0
  grep -rqs --exclude="$(basename "$f")" "log_format[[:space:]]\+wp_timed" /etc/nginx/ && have_format=1

  {
    printf '# Создано wp-autoinstall\n'
    if (( have_format == 0 )); then
      printf '# Лог со временем ответа: медленные запросы ищутся одной командой\n'
      printf '#   awk \x27{for(i=NF;i>0;i--) if($i ~ /^[0-9]+\\.[0-9]+$/){if($i+0>5) print; break}}\x27 access.log\n'
      printf 'log_format wp_timed \x27$remote_addr [$time_local] "$request" $status \x27\n'
      printf '                    \x27$body_bytes_sent $request_time "$http_referer" "$http_user_agent"\x27;\n'
      printf '\n'
    fi
    printf '# Поиск по сайту — самый дорогой запрос в WordPress (LIKE по всем записям).\n'
    printf '# Ключ зоны пуст для обычных страниц, поэтому лимит их не касается.\n'
    printf 'map $arg_s $wp_search_key {\n'
    printf '    default        "";\n'
    printf '    "~.+"          $binary_remote_addr;\n'
    printf '}\n'
    printf 'limit_req_zone $wp_search_key zone=wpsearch:10m rate=%s;\n' "${SEARCH_RATE:-20r/m}"
    printf 'limit_req_status 429;\n'
    if [[ "${INSTALL_CACHE}" == "yes" ]]; then
      printf '\n# Кэш готовых страниц: боты и анонимные посетители не доходят до PHP\n'
      printf 'fastcgi_cache_path /var/cache/nginx/wp levels=1:2 keys_zone=WPCACHE:100m\n'
      printf '                   inactive=60m max_size=512m;\n'
      printf 'fastcgi_cache_key "$scheme$request_method$host$request_uri";\n'
    fi
  } > "$f"

  if [[ "${INSTALL_CACHE}" == "yes" ]]; then
    mkdir -p /var/cache/nginx/wp
    chown -R www-data:www-data /var/cache/nginx
  fi
  ok "Общие настройки nginx: ${f}"
}

configure_webserver() {
  info "Настройка веб-сервера (${WEB_SERVER})"
  BODY_MAX="$(double_size "$UPLOAD_MAX")"

  # каталог для собственных правил: сюда кладутся редиректы и заглушки старого сайта
  EXTRA_DIR="/etc/nginx/wp-autoinstall/${SITE_DOMAIN}.d"
  [[ "$WEB_SERVER" == "apache" ]] && EXTRA_DIR="/etc/apache2/wp-autoinstall/${SITE_DOMAIN}.d"
  mkdir -p "$EXTRA_DIR"
  if [[ -n "${NGINX_EXTRA_CONF:-}" ]]; then
    if [[ -r "$NGINX_EXTRA_CONF" ]]; then
      cp "$NGINX_EXTRA_CONF" "${EXTRA_DIR}/50-custom.conf"
      ok "Свои правила подключены: ${EXTRA_DIR}/50-custom.conf"
    else
      warn "Файл своих правил не найден: ${NGINX_EXTRA_CONF}"
    fi
  fi

  case "$WEB_SERVER" in
    nginx)  configure_nginx ;;
    apache) configure_apache ;;
    *) die "Неизвестный веб-сервер: ${WEB_SERVER}" ;;
  esac
}

# --------------------------------------------------------------------- NGINX
configure_nginx() {
  local conf="/etc/nginx/sites-available/${SITE_DOMAIN}.conf"
  nginx_global_snippet
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

    access_log /var/log/nginx/__DOMAIN__.access.log wp_timed;
    error_log  /var/log/nginx/__DOMAIN__.error.log;

__CACHE_VARS__
    # Свои правила для этого сайта: редиректы, заглушки старых адресов и прочее.
    # Файлы кладутся в __EXTRA_DIR__ и подхватываются после перезагрузки nginx.
    include __EXTRA_DIR__/*.conf;

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { allow all; log_not_found off; access_log off; }

    location / {
        # Поиск по сайту ограничен по частоте: на большой базе он выполняется
        # десятки секунд и способен занять все воркеры PHP-FPM.
        limit_req zone=wpsearch burst=5 nodelay;
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
__CACHE_FCGI__
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

  local cache_vars="" cache_fcgi=""
  if [[ "${INSTALL_CACHE}" == "yes" ]]; then
    cache_vars="$(cat <<'CV'
    # Кэш страниц: не кэшируем POST, запросы с параметрами, админку и авторизованных
    set $skip_cache 0;
    if ($request_method = POST)                     { set $skip_cache 1; }
    if ($query_string != "")                        { set $skip_cache 1; }
    if ($request_uri ~* "/wp-admin/|/xmlrpc\\.php|wp-.*\\.php|/feed/|sitemap.*\\.xml") { set $skip_cache 1; }
    if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_logged_in") { set $skip_cache 1; }
CV
)"
    cache_fcgi="$(cat <<'CF'

        fastcgi_cache WPCACHE;
        fastcgi_cache_valid 200 301 302 60m;
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache $skip_cache;
        fastcgi_cache_use_stale error timeout updating http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        add_header X-FastCGI-Cache $upstream_cache_status always;
CF
)"
  fi

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
  tpl="${tpl//__CACHE_VARS__/$cache_vars}"
  tpl="${tpl//__CACHE_FCGI__/$cache_fcgi}"
  tpl="${tpl//__EXTRA_DIR__/$EXTRA_DIR}"
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

    # Свои правила для этого сайта (редиректы, заглушки старых адресов)
    IncludeOptional ${EXTRA_DIR}/*.conf

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
