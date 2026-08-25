#!/usr/bin/env bash
# shellcheck disable=SC2034  # переменные используются подключаемыми модулями
#
# tests/smoke-test.sh — проверка логики установщика без реальной установки.
#
# Подменяет apt/systemctl/mysql/curl заглушками и прогоняет install.sh целиком,
# после чего проверяет содержимое сгенерированных файлов.
#
# ВНИМАНИЕ: запускать только в одноразовом контейнере или виртуальной машине —
# скрипт создаёт файлы в /etc/nginx, /etc/php и /var/log.
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
MOCK="${TMP}/bin"
WPDIR="${TMP}/site"
PHPV="${TEST_PHP_VER:-8.4}"
FAILED=0
FAILLOG="${TMP}/failures.txt"

mkdir -p "$MOCK"
: > "$FAILLOG"

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; printf '%s\n' "$1" >> "$FAILLOG"; FAILED=1; }
check() { # check "описание" "файл" "подстрока"
  if grep -qF -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1 (нет «$3» в $2)"; fi
}

# ------------------------------------------------------------------ заглушки
cat > "${MOCK}/apt-get" <<'M'
#!/bin/sh
exit 0
M
cat > "${MOCK}/apt-cache" <<'M'
#!/bin/sh
echo "  Candidate: 1.0"
exit 0
M
cat > "${MOCK}/dpkg-query" <<'M'
#!/bin/sh
exit 1
M
cat > "${MOCK}/systemctl" <<'M'
#!/bin/sh
case "$1" in
  is-active) exit 1 ;;
  list-unit-files) echo "php__PHPV__-fpm.service enabled"; echo "mariadb.service enabled"; exit 0 ;;
esac
exit 0
M
cat > "${MOCK}/mysql" <<'M'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    *SCHEMA_NAME*) exit 0 ;;   # база не существует
  esac
done
exit 0
M
cat > "${MOCK}/mysqldump" <<'M'
#!/bin/sh
echo "-- dump"
M
cat > "${MOCK}/nginx" <<'M'
#!/bin/sh
exit 0
M
for a in a2enmod a2ensite a2dissite a2enconf apache2ctl; do
  printf '#!/bin/sh\nexit 0\n' > "${MOCK}/${a}"
done
cat > "${MOCK}/sudo" <<'M'
#!/bin/sh
case "$*" in
  *wp-install-*) exit 0 ;;     # установка ядра WordPress
esac
[ "$1" = "-u" ] && shift 2
exec "$@"
M
cat > "${MOCK}/curl" <<'M'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *secret-key*)
    for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
      echo "define('$k', 'test-salt-value-$k');"
    done
    exit 0 ;;
  *wp-cli.phar*) exit 1 ;;      # проверяем путь установки без WP-CLI
  *wordpress.org/latest*)
    d=$(mktemp -d)
    mkdir -p "$d/wordpress/wp-includes" "$d/wordpress/wp-content/themes" "$d/wordpress/wp-admin"
    echo "<?php \$wp_version='6.9';" > "$d/wordpress/wp-includes/version.php"
    echo "<?php // sample" > "$d/wordpress/wp-config-sample.php"
    echo "<?php // index" > "$d/wordpress/index.php"
    tar -czf "$out" -C "$d" wordpress
    rm -rf "$d"; exit 0 ;;
  *phpmyadmin*)
    d=$(mktemp -d); mkdir -p "$d/phpMyAdmin-x/setup"
    echo "<?php // pma" > "$d/phpMyAdmin-x/index.php"
    tar -czf "$out" -C "$d" phpMyAdmin-x
    rm -rf "$d"; exit 0 ;;
esac
exit 1
M
sed -i "s/__PHPV__/${PHPV}/" "${MOCK}/systemctl"
chmod +x "${MOCK}"/*

# ------------------------------------------------- окружение, как после apt
mkdir -p "/etc/php/${PHPV}/fpm/conf.d" "/etc/php/${PHPV}/fpm/pool.d" "/etc/php/${PHPV}/cli/conf.d"
printf 'listen = /run/php/php%s-fpm.sock\n' "$PHPV" > "/etc/php/${PHPV}/fpm/pool.d/www.conf"
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/log/nginx

cat > "${TMP}/test.conf" <<CFG
SITE_DOMAIN=test.example.com
SITE_TITLE=Тестовый сайт
WP_LOCALE=ru_RU
WP_PATH=${WPDIR}
WP_ADMIN_USER=testadmin
WP_ADMIN_PASS=SuperSecret123
WP_EMAIL=admin@test.example.com
DB_NAME=wp_smoketest
DB_USER=wp_smokeuser
DB_PASS=DbPassw0rd123
TABLE_PREFIX=sm_
DB_ENGINE=mariadb
WEB_SERVER=nginx
PHP_VERSION=${PHPV}
UPLOAD_MAX=256M
MAX_INPUT_VARS=5000
PHP_MEMORY_LIMIT=512M
MAX_EXEC_TIME=600
INSTALL_PMA=yes
INSTALL_SSL=no
INSTALL_FIREWALL=no
CFG

printf '\n\033[1mПрогон install.sh с заглушками\033[0m\n'
if PATH="${MOCK}:${PATH}" LOG_FILE="${TMP}/install.log" \
   bash "${ROOT}/install.sh" -c "${TMP}/test.conf" -y --no-tui --force > "${TMP}/out.txt" 2>&1; then
  pass "install.sh завершился успешно"
else
  fail "install.sh завершился с ошибкой"
  tail -n 30 "${TMP}/out.txt"
  tail -n 30 "${TMP}/install.log" 2>/dev/null || true
fi

printf '\n\033[1mПроверка результатов\033[0m\n'
CFGF="${WPDIR}/wp-config.php"
check "wp-config.php: имя базы"        "$CFGF" "define( 'DB_NAME', 'wp_smoketest' );"
check "wp-config.php: пользователь"    "$CFGF" "define( 'DB_USER', 'wp_smokeuser' );"
check "wp-config.php: пароль"          "$CFGF" "define( 'DB_PASSWORD', 'DbPassw0rd123' );"
check "wp-config.php: префикс таблиц"  "$CFGF" "\$table_prefix = 'sm_';"
check "wp-config.php: адрес сайта"     "$CFGF" "define( 'WP_HOME', 'http://test.example.com' );"
check "wp-config.php: соли"            "$CFGF" "AUTH_KEY"
check "wp-config.php: лимит памяти"    "$CFGF" "define( 'WP_MEMORY_LIMIT', '512M' );"

INI="/etc/php/${PHPV}/fpm/conf.d/99-wordpress.ini"
check "php.ini: upload_max_filesize"   "$INI" "upload_max_filesize = 256M"
check "php.ini: post_max_size х2"      "$INI" "post_max_size = 512M"
check "php.ini: max_input_vars"        "$INI" "max_input_vars = 5000"
check "php.ini: memory_limit"          "$INI" "memory_limit = 512M"
check "php.ini: max_execution_time"    "$INI" "max_execution_time = 600"

NG="/etc/nginx/sites-available/test.example.com.conf"
check "nginx: имя сервера"             "$NG" "server_name test.example.com www.test.example.com;"
check "nginx: корень сайта"            "$NG" "root ${WPDIR};"
check "nginx: размер тела запроса"     "$NG" "client_max_body_size 512M;"
check "nginx: сокет PHP-FPM"           "$NG" "fastcgi_pass unix:/run/php/php${PHPV}-fpm.sock;"
check "nginx: блок phpMyAdmin"         "$NG" "location ^~ /phpmyadmin/"
check "nginx: плейсхолдеры заменены"   "$NG" "index index.php"
if grep -q "__" "$NG"; then fail "nginx: в конфиге остались плейсхолдеры __XXX__"; else pass "nginx: плейсхолдеров не осталось"; fi
[[ -L "/etc/nginx/sites-enabled/test.example.com.conf" ]] && pass "nginx: сайт включён (симлинк)" || fail "nginx: симлинк не создан"

CRED="/root/wp-test.example.com-credentials.txt"
check "файл доступов: пароль админа"   "$CRED" "SuperSecret123"
check "файл доступов: параметры PHP"   "$CRED" "5000"
[[ "$(stat -c %a "$CRED" 2>/dev/null)" == "600" ]] && pass "файл доступов: права 600" || fail "файл доступов: неверные права"

[[ -f "${WPDIR}/wp-includes/version.php" ]] && pass "WordPress распакован" || fail "WordPress не распакован"
[[ "$(stat -c %a "$CFGF" 2>/dev/null)" == "640" ]] && pass "wp-config.php: права 640" || fail "wp-config.php: неверные права"
[[ -f "/usr/share/phpmyadmin/index.php" ]] && pass "phpMyAdmin установлен" || fail "phpMyAdmin не установлен"
[[ -f "/usr/share/phpmyadmin/config.inc.php" ]] && pass "phpMyAdmin: config.inc.php создан" || fail "phpMyAdmin: нет config.inc.php"

# ============================================================ Apache-вариант
printf '\n\033[1mПрогон с Apache\033[0m\n'
mkdir -p /etc/apache2/sites-available /etc/apache2/sites-enabled /var/log/apache2
sed -e 's/^WEB_SERVER=.*/WEB_SERVER=apache/' \
    -e 's/^SITE_DOMAIN=.*/SITE_DOMAIN=apache.example.com/' \
    -e "s#^WP_PATH=.*#WP_PATH=${TMP}/site-apache#" \
    "${TMP}/test.conf" > "${TMP}/test-apache.conf"
if PATH="${MOCK}:${PATH}" LOG_FILE="${TMP}/install-apache.log" \
   bash "${ROOT}/install.sh" -c "${TMP}/test-apache.conf" -y --no-tui --force > "${TMP}/out-apache.txt" 2>&1; then
  pass "install.sh (apache) завершился успешно"
else
  fail "install.sh (apache) завершился с ошибкой"
  tail -n 20 "${TMP}/out-apache.txt"
fi
AP="/etc/apache2/sites-available/apache.example.com.conf"
check "apache: ServerName"             "$AP" "ServerName apache.example.com"
check "apache: DocumentRoot"           "$AP" "DocumentRoot ${TMP}/site-apache"
check "apache: обработчик PHP-FPM"     "$AP" "SetHandler \"proxy:unix:/run/php/php${PHPV}-fpm.sock|fcgi://localhost\""
check "apache: AllowOverride All"      "$AP" "AllowOverride All"
check "apache: alias phpMyAdmin"       "$AP" "Alias /phpmyadmin /usr/share/phpmyadmin"
[[ -f "${TMP}/site-apache/.htaccess" ]] && pass "apache: .htaccess создан" || fail "apache: нет .htaccess"

# ======================================= экран установки (нужен псевдотерминал)
if command -v script >/dev/null 2>&1; then
  printf '\n\033[1mПроверка экрана установки\033[0m\n'
  sed -e 's/^SITE_DOMAIN=.*/SITE_DOMAIN=screen.example.com/' \
      -e "s#^WP_PATH=.*#WP_PATH=${TMP}/site-screen#" \
      -e 's/^WEB_SERVER=.*/WEB_SERVER=nginx/' \
      "${TMP}/test.conf" > "${TMP}/test-screen.conf"
  TS="${TMP}/typescript"
  TERM=xterm script -qec \
    "PATH=${MOCK}:\$PATH LOG_FILE=${TMP}/install-screen.log bash ${ROOT}/install.sh -c ${TMP}/test-screen.conf -y --force" \
    "$TS" >/dev/null 2>&1 || true
  if grep -q 'Установка WordPress' "$TS"; then pass "экран: рамка с параметрами нарисована"; else fail "экран: рамки нет"; fi
  if grep -q 'screen.example.com' "$TS"; then pass "экран: параметры выведены в рамке"; else fail "экран: параметров нет"; fi
  if grep -q 'Этап .* из ' "$TS"; then pass "экран: строка этапа"; else fail "экран: строки этапа нет"; fi
  if grep -qE '(█|#)+' "$TS"; then pass "экран: прогресс-бар"; else fail "экран: прогресс-бара нет"; fi
  if grep -qP '\x1b\[[0-9]+;1H' "$TS"; then pass "экран: вывод на фиксированные строки"; else fail "экран: нет позиционирования курсора"; fi
  if grep -q '100%' "$TS"; then pass "экран: прогресс дошёл до 100%"; else fail "экран: нет 100%"; fi

  # --plain обязан отключать экран
  TS2="${TMP}/typescript-plain"
  sed -e 's/^SITE_DOMAIN=.*/SITE_DOMAIN=plain.example.com/' \
      -e "s#^WP_PATH=.*#WP_PATH=${TMP}/site-plain#" \
      "${TMP}/test.conf" > "${TMP}/test-plain.conf"
  TERM=xterm script -qec \
    "PATH=${MOCK}:\$PATH LOG_FILE=${TMP}/install-plain.log bash ${ROOT}/install.sh -c ${TMP}/test-plain.conf -y --force --plain" \
    "$TS2" >/dev/null 2>&1 || true
  if grep -q 'Установка WordPress ─' "$TS2"; then fail "--plain: экран всё равно нарисован"; else pass "--plain: обычный вывод без экрана"; fi
else
  printf '\n  (пропуск проверки экрана: нет команды script)\n'
fi

# ================================================= модульные проверки функций
printf '\n\033[1mПроверка отдельных функций\033[0m\n'
(
  set +e
  ASSUME_YES=0; VERBOSE=0; UI_MODE=text; LOG_FILE="${TMP}/unit.log"
  # shellcheck source=/dev/null
  . "${ROOT}/lib/common.sh"
  # shellcheck source=/dev/null
  . "${ROOT}/lib/ui.sh"
  # shellcheck source=/dev/null
  . "${ROOT}/lib/packages.sh"
  # shellcheck source=/dev/null
  . "${ROOT}/lib/prompts.sh"

  v_host "example.com"      && pass "v_host: домен принят"           || fail "v_host: домен отклонён"
  v_host "192.168.1.10"     && pass "v_host: IP принят"              || fail "v_host: IP отклонён"
  v_host "не домен" 2>/dev/null >/dev/null && fail "v_host: мусор принят" || pass "v_host: мусор отклонён"
  v_email "a@b.co"          && pass "v_email: адрес принят"          || fail "v_email: адрес отклонён"
  v_email "a@b" >/dev/null  && fail "v_email: неверный адрес принят" || pass "v_email: неверный адрес отклонён"
  v_ident "wp_db1"          && pass "v_ident: имя БД принято"        || fail "v_ident: имя БД отклонено"
  v_ident "1db" >/dev/null  && fail "v_ident: имя с цифры принято"   || pass "v_ident: имя с цифры отклонено"
  v_dbpass "qwe" >/dev/null && fail "v_dbpass: короткий пароль принят" || pass "v_dbpass: короткий пароль отклонён"
  v_dbpass "abc'\''def123" >/dev/null && fail "v_dbpass: кавычка принята" || pass "v_dbpass: кавычка отклонена"
  v_size "128M"             && pass "v_size: 128M принят"            || fail "v_size: 128M отклонён"
  v_size "128" >/dev/null   && fail "v_size: без единицы принят"     || pass "v_size: без единицы отклонён"

  [[ "$(double_size 128M)" == "256M" ]] && pass "double_size: 128M -> 256M" || fail "double_size: неверно"
  [[ "$(double_size 1G)"   == "2048M" ]] && pass "double_size: 1G -> 2048M" || fail "double_size: неверно (1G)"
  [[ "$(size_to_mb 512M)"  == "512"  ]] && pass "size_to_mb: 512M -> 512"   || fail "size_to_mb: неверно"

  # выбор пункта меню в текстовом режиме
  UPLOAD_MAX=""
  ui_menu UPLOAD_MAX "Размер:" "128M" v_size "8M|" "64M|" "256M|" "512M|" >/dev/null <<< "3"
  [[ "$UPLOAD_MAX" == "256M" ]] && pass "меню: выбран третий пункт (256M)" || fail "меню: получено «$UPLOAD_MAX»"

  # Enter = значение по умолчанию
  MAX_INPUT_VARS=""
  ui_menu MAX_INPUT_VARS "Переменные:" "3000" v_int "1000|" "3000|" "5000|" >/dev/null <<< ""
  [[ "$MAX_INPUT_VARS" == "3000" ]] && pass "меню: Enter даёт значение по умолчанию" || fail "меню: Enter дал «$MAX_INPUT_VARS»"

  # свой вариант
  MAX_INPUT_VARS=""
  ui_menu MAX_INPUT_VARS "Переменные:" "3000" v_int "1000|" "3000|" "5000|" >/dev/null <<< $'4\n7777' 
  [[ "$MAX_INPUT_VARS" == "7777" ]] && pass "меню: свой вариант (7777)" || fail "меню: свой вариант дал «$MAX_INPUT_VARS»"

  exit 0
) || FAILED=1

printf '\n'
[[ -s "$FAILLOG" ]] && FAILED=1
if [[ "$FAILED" == "0" ]]; then
  printf '\033[32mВсе проверки пройдены.\033[0m\n'
else
  printf '\033[31mЕсть непройденные проверки. Полный вывод: %s\033[0m\n' "${TMP}/out.txt"
fi
printf 'Временный каталог теста: %s\n' "$TMP"
exit "$FAILED"
