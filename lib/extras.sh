#!/usr/bin/env bash
# lib/extras.sh — phpMyAdmin, SSL (Let's Encrypt), UFW + fail2ban, итоговая сводка.
# shellcheck shell=bash

PMA_DIR="/usr/share/phpmyadmin"

# ------------------------------------------------------------------ phpMyAdmin
setup_phpmyadmin() {
  [[ "${INSTALL_PMA}" == "yes" ]] || return 0
  info "Установка phpMyAdmin"

  if [[ -f "${PMA_DIR}/index.php" ]]; then
    ok "phpMyAdmin уже установлен в ${PMA_DIR}"
  else
    step "Загрузка последней версии с phpmyadmin.net"
    local tgz="/tmp/phpmyadmin.tar.gz"
    if ! run curl -fL --retry 3 -o "$tgz" \
        "https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz"; then
      warn "Не удалось скачать phpMyAdmin — пробуем пакет из репозитория."
      if apt_candidate_exists phpmyadmin; then
        echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
        echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect none" | debconf-set-selections
        apt_install phpmyadmin
      else
        warn "phpMyAdmin установить не удалось — пропускаем."
        INSTALL_PMA=no; return 0
      fi
    else
      rm -rf /tmp/pma-extract && mkdir -p /tmp/pma-extract
      run tar -xzf "$tgz" -C /tmp/pma-extract --strip-components=1
      rm -rf "$PMA_DIR"
      mkdir -p "$PMA_DIR"
      cp -a /tmp/pma-extract/. "$PMA_DIR"/
      rm -rf /tmp/pma-extract "$tgz"
    fi
  fi

  # конфигурация
  local secret; secret="$(rand_pass 32)"
  cat > "${PMA_DIR}/config.inc.php" <<PMACFG
<?php
/* Создано wp-autoinstall */
\$cfg['blowfish_secret'] = '${secret}';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type']       = 'cookie';
\$cfg['Servers'][\$i]['host']            = 'localhost';
\$cfg['Servers'][\$i]['compress']        = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir']   = '';
\$cfg['TempDir']   = '/var/lib/phpmyadmin/tmp';
PMACFG

  mkdir -p /var/lib/phpmyadmin/tmp
  chown -R www-data:www-data /var/lib/phpmyadmin
  chmod 700 /var/lib/phpmyadmin/tmp
  chown -R root:www-data "$PMA_DIR"
  chmod 640 "${PMA_DIR}/config.inc.php"
  rm -rf "${PMA_DIR}/setup"
  ok "phpMyAdmin установлен (${PMA_DIR}), адрес: /phpmyadmin/"
}

# ------------------------------------------------------------------------ SSL
setup_ssl() {
  [[ "${INSTALL_SSL}" == "yes" ]] || return 0
  if is_ip "$SITE_DOMAIN"; then
    warn "SSL пропущен: Let's Encrypt не выдаёт сертификаты на IP-адрес."
    INSTALL_SSL=no; return 0
  fi
  info "Выпуск SSL-сертификата Let's Encrypt"

  local plugin_pkg plugin_flag
  if [[ "$WEB_SERVER" == "nginx" ]]; then
    plugin_pkg="python3-certbot-nginx"; plugin_flag="--nginx"
  else
    plugin_pkg="python3-certbot-apache"; plugin_flag="--apache"
  fi
  apt_install certbot "$plugin_pkg"

  step "Запрос сертификата для ${SITE_DOMAIN}"
  if run certbot "$plugin_flag" -n --agree-tos -m "$WP_EMAIL" --redirect \
        -d "$SITE_DOMAIN" -d "www.${SITE_DOMAIN}"; then
    ok "Сертификат выпущен для ${SITE_DOMAIN} и www.${SITE_DOMAIN}"
  elif run certbot "$plugin_flag" -n --agree-tos -m "$WP_EMAIL" --redirect -d "$SITE_DOMAIN"; then
    ok "Сертификат выпущен для ${SITE_DOMAIN}"
  else
    warn "Не удалось выпустить сертификат (проверьте, что домен указывает на этот сервер и порт 80 открыт)."
    warn "Повторить позже: certbot ${plugin_flag} -d ${SITE_DOMAIN}"
    INSTALL_SSL=no
    return 0
  fi

  run systemctl enable certbot.timer || true
  run systemctl start certbot.timer || true
  switch_site_to_https
}

# ------------------------------------------------------------ UFW + fail2ban
setup_firewall() {
  [[ "${INSTALL_FIREWALL}" == "yes" ]] || return 0
  info "Настройка UFW и fail2ban"

  apt_install ufw fail2ban
  step "Правила UFW"
  run ufw --force reset || true
  run ufw default deny incoming || true
  run ufw default allow outgoing || true
  run ufw allow OpenSSH || run ufw allow 22/tcp || true
  if [[ "$WEB_SERVER" == "nginx" ]]; then
    run ufw allow 'Nginx Full' || run ufw allow 80,443/tcp || true
  else
    run ufw allow 'Apache Full' || run ufw allow 80,443/tcp || true
  fi
  run ufw --force enable
  ok "UFW включён (открыты 22, 80, 443)"

  local access_log
  if [[ "$WEB_SERVER" == "nginx" ]]; then
    access_log="/var/log/nginx/${SITE_DOMAIN}.access.log"
  else
    access_log="/var/log/apache2/${SITE_DOMAIN}-access.log"
  fi
  touch "$access_log" 2>/dev/null || true

  cat > /etc/fail2ban/filter.d/wordpress-auth.conf <<'F2B'
# Создано wp-autoinstall: подбор паролей к wp-login.php и xmlrpc.php
[Definition]
failregex = ^<HOST> .* "POST [^"]*/wp-login\.php
            ^<HOST> .* "POST [^"]*/xmlrpc\.php
ignoreregex =
F2B

  cat > /etc/fail2ban/jail.d/wp-autoinstall.local <<JAIL
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
bantime  = 1h

[wordpress-auth]
enabled  = true
filter   = wordpress-auth
port     = http,https
logpath  = ${access_log}
backend  = auto
maxretry = 5
findtime = 5m
bantime  = 1h
JAIL

  run systemctl enable fail2ban || true
  if run systemctl restart fail2ban; then
    ok "fail2ban защищает SSH и вход в WordPress"
  else
    warn "fail2ban не запустился — проверьте: systemctl status fail2ban"
  fi
}

# --------------------------------------------------------- доступы и сводка
save_credentials() {
  CRED_FILE="/root/wp-${SITE_DOMAIN}-credentials.txt"
  cat > "$CRED_FILE" <<CRED
=======================================================
 WordPress — данные доступа (${SITE_DOMAIN})
 Установлено: $(date '+%F %T')
=======================================================

Адрес сайта .............. ${WP_URL_SCHEME}://${SITE_DOMAIN}
Панель управления ........ ${WP_URL_SCHEME}://${SITE_DOMAIN}/wp-admin/
  Логин .................. ${WP_ADMIN_USER}
  Пароль ................. ${WP_ADMIN_PASS}
  Email .................. ${WP_EMAIL}

База данных .............. ${DB_NAME}
  Пользователь ........... ${DB_USER}
  Пароль ................. ${DB_PASS}
  Хост ................... localhost
  Префикс таблиц ......... ${TABLE_PREFIX}

Каталог сайта ............ ${WP_PATH}
Веб-сервер ............... ${WEB_SERVER}
PHP ...................... ${PHP_VER} (${PHP_FPM_SERVICE})
СУБД ..................... ${DB_SERVICE}
phpMyAdmin ............... $( [[ "$INSTALL_PMA" == "yes" ]] && echo "${WP_URL_SCHEME}://${SITE_DOMAIN}/phpmyadmin/" || echo "не установлен" )
SSL ...................... $( [[ "$INSTALL_SSL" == "yes" ]] && echo "Let's Encrypt, автопродление включено" || echo "не настроен" )
Брандмауэр ............... $( [[ "$INSTALL_FIREWALL" == "yes" ]] && echo "UFW + fail2ban" || echo "не настроен" )

Параметры PHP:
  upload_max_filesize .... ${UPLOAD_MAX}
  post_max_size .......... $(double_size "$UPLOAD_MAX")
  memory_limit ........... ${PHP_MEMORY_LIMIT}
  max_input_vars ......... ${MAX_INPUT_VARS}
  max_execution_time ..... ${MAX_EXEC_TIME}

Храните этот файл в надёжном месте и удалите с сервера,
если он больше не нужен.
CRED
  chmod 600 "$CRED_FILE"
  ok "Данные доступа сохранены: ${CRED_FILE}"
}

print_summary() {
  printf '\n%s%s%s\n' "$C_GREEN$C_BOLD" "═══════════════════════════════════════════════════════" "$C_RESET"
  printf '%s  WordPress установлен и готов к работе%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
  printf '%s%s%s\n\n' "$C_GREEN$C_BOLD" "═══════════════════════════════════════════════════════" "$C_RESET"
  printf '  Сайт ............ %s%s://%s%s\n' "$C_BOLD" "$WP_URL_SCHEME" "$SITE_DOMAIN" "$C_RESET"
  printf '  Админка ......... %s%s://%s/wp-admin/%s\n' "$C_BOLD" "$WP_URL_SCHEME" "$SITE_DOMAIN" "$C_RESET"
  printf '  Логин ........... %s\n' "$WP_ADMIN_USER"
  printf '  Пароль .......... %s\n' "$WP_ADMIN_PASS"
  if [[ "$INSTALL_PMA" == "yes" ]]; then
    printf '  phpMyAdmin ...... %s://%s/phpmyadmin/ (вход: %s)\n' "$WP_URL_SCHEME" "$SITE_DOMAIN" "$DB_USER"
  fi
  printf '\n  База данных ..... %s / %s\n' "$DB_NAME" "$DB_USER"
  printf '  Каталог сайта ... %s\n' "$WP_PATH"
  printf '  Доступы ......... %s\n' "$CRED_FILE"
  printf '  Журнал .......... %s\n' "$LOG_FILE"
  if is_ip "$SITE_DOMAIN"; then
    printf '\n  %sПодсказка:%s сайт работает по IP. Когда направите домен на этот\n' "$C_YELLOW" "$C_RESET"
    printf '  сервер, перезапустите скрипт с --domain ВАШ.ДОМЕН --ssl\n'
  fi
  printf '\n'
}
