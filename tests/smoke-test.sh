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
    *VERSION*)     echo "10.11.11-MariaDB-0+deb12u1"; exit 0 ;;
    *SCHEMA_NAME*) exit 0 ;;   # база не существует
  esac
done
exit 0
M
printf '#!/bin/sh\nexit 0\n' > "${MOCK}/php-fpm${PHPV}"
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

# пользователь веб-сервера может отсутствовать на голой машине (например, в CI)
id www-data >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin www-data

# ------------------------------------------------- окружение, как после apt
mkdir -p "/etc/php/${PHPV}/fpm/conf.d" "/etc/php/${PHPV}/fpm/pool.d" "/etc/php/${PHPV}/cli/conf.d"
cat > "/etc/php/${PHPV}/fpm/pool.d/www.conf" <<POOL
[www]
user = www-data
group = www-data
listen = /run/php/php${PHPV}-fpm.sock
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
;request_terminate_timeout = 0
;slowlog = /var/log/\$pool.log.slow
POOL
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d /var/log/nginx
mkdir -p /etc/mysql/mariadb.conf.d /var/log/mysql

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
INSTALL_CACHE=yes
SETUP_SWAP=no
CREATE_ROBOTS=yes
DB_MAX_STATEMENT_TIME=30
SEARCH_RATE=20r/m
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
if [[ -L "/etc/nginx/sites-enabled/test.example.com.conf" ]]; then
  pass "nginx: сайт включён (симлинк)"
else
  fail "nginx: симлинк не создан"
fi

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

# ================================ устойчивость под нагрузкой (тюнинг)
printf '\n\033[1mТюнинг под нагрузкой\033[0m\n'

POOL="/etc/php/${PHPV}/fpm/pool.d/www.conf"
if grep -qE '^pm\.max_children = [0-9]+' "$POOL"; then
  CH=$(grep -oP '^pm\.max_children = \K[0-9]+' "$POOL")
  if (( CH >= 5 )); then pass "PHP-FPM: воркеров ${CH} (было 5 по умолчанию)"
  else fail "PHP-FPM: воркеров ${CH} — меньше минимума"; fi
else
  fail "PHP-FPM: pm.max_children не выставлен"
fi
check "PHP-FPM: обрыв зависшего запроса" "$POOL" "request_terminate_timeout ="
check "PHP-FPM: журнал медленных"        "$POOL" "request_slowlog_timeout = 5s"
check "PHP-FPM: slowlog"                 "$POOL" "slowlog = /var/log/php${PHPV}-fpm-slow.log"
if grep -qE '^pm\.max_spare_servers' "$POOL"; then
  SP=$(grep -oP '^pm\.max_spare_servers = \K[0-9]+' "$POOL")
  CH=$(grep -oP '^pm\.max_children = \K[0-9]+' "$POOL")
  (( SP <= CH )) && pass "PHP-FPM: max_spare_servers не больше max_children" \
                 || fail "PHP-FPM: max_spare_servers ${SP} > max_children ${CH}"
fi

DBCNF="/etc/mysql/mariadb.conf.d/99-wp-autoinstall.cnf"
check "СУБД: обрыв тяжёлого запроса (MariaDB)" "$DBCNF" "max_statement_time = 30"
check "СУБД: размер буфера"                    "$DBCNF" "innodb_buffer_pool_size ="
check "СУБД: журнал медленных запросов"        "$DBCNF" "slow_query_log = 1"

GLOB="/etc/nginx/conf.d/00-wp-autoinstall.conf"
check "nginx: формат лога со временем ответа" "$GLOB" "log_format wp_timed"
check "nginx: зона лимита поиска"             "$GLOB" "limit_req_zone \$wp_search_key zone=wpsearch"
check "nginx: ключ зоны пуст вне поиска"      "$GLOB" 'default        "";'
check "nginx: зона кэша страниц"              "$GLOB" "fastcgi_cache_path /var/cache/nginx/wp"

NG="/etc/nginx/sites-available/test.example.com.conf"
check "nginx: лимит применён к поиску"   "$NG" "limit_req zone=wpsearch"
check "nginx: лог с wp_timed"            "$NG" "access.log wp_timed"
check "nginx: подключение своих правил"  "$NG" "include /etc/nginx/wp-autoinstall/test.example.com.d/*.conf;"
check "nginx: кэш включён в php-локации" "$NG" "fastcgi_cache WPCACHE;"
check "nginx: кэш обходит админку"       "$NG" "set \$skip_cache 1;"
check "nginx: заголовок статуса кэша"    "$NG" "X-FastCGI-Cache"
[[ -d "/etc/nginx/wp-autoinstall/test.example.com.d" ]] && pass "nginx: каталог своих правил создан" || fail "nginx: каталога своих правил нет"

ROB="${WPDIR}/robots.txt"
check "robots.txt: поиск закрыт"       "$ROB" "Disallow: /*?s="
check "robots.txt: админка закрыта"    "$ROB" "Disallow: /wp-admin/"
check "robots.txt: admin-ajax разрешён" "$ROB" "Allow: /wp-admin/admin-ajax.php"

[[ -x /usr/local/bin/wp-autoinstall-check ]] && pass "команда проверки установлена" || fail "команды проверки нет"
check "файл доступов: раздел устойчивости" "$CRED" "Обрыв тяжёлого SQL"

# свой файл правил через --extra-conf
EXTRA_SRC="${TMP}/legacy.conf"
printf 'location ^~ /search/ { return 410; }\n' > "$EXTRA_SRC"
sed -e 's/^SITE_DOMAIN=.*/SITE_DOMAIN=legacy.example.com/' \
    -e "s#^WP_PATH=.*#WP_PATH=${TMP}/site-legacy#" "${TMP}/test.conf" > "${TMP}/test-legacy.conf"
PATH="${MOCK}:${PATH}" LOG_FILE="${TMP}/legacy.log" \
  bash "${ROOT}/install.sh" -c "${TMP}/test-legacy.conf" -y --force --extra-conf "$EXTRA_SRC" \
  > "${TMP}/legacy-out.txt" 2>&1 || true
if [[ -f /etc/nginx/wp-autoinstall/legacy.example.com.d/50-custom.conf ]]; then
  pass "--extra-conf: свои правила скопированы"
else
  fail "--extra-conf: правила не скопированы"
fi

# после установки ВТОРОГО сайта log_format должен остаться — на него ссылаются
# vhost'ы обоих сайтов, без него nginx не стартует
check "второй сайт: log_format не потерялся" "$GLOB" "log_format wp_timed"

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

# ================================ проверка недопустимых значений
printf '\n\033[1mПроверка значений параметров\033[0m\n'

bad_value() { # bad_value ОПИСАНИЕ КЛЮЧ ЗНАЧЕНИЕ ОЖИДАЕМЫЙ_КУСОК_ОШИБКИ
  local out
  out="$(PATH="${MOCK}:${PATH}" LOG_FILE="${TMP}/bad.log" \
        bash "${ROOT}/install.sh" -c "${TMP}/test.conf" -y --force "$2" "$3" 2>&1 || true)"
  if grep -qF "$4" <<< "$out"; then
    pass "$1"
  else
    fail "$1"; echo "$out" | tail -3
  fi
}

bad_value "мусор в --search-rate отклонён"   --search-rate  "быстро"  "Неверный формат"
bad_value "мусор в --swap-size отклонён"     --swap-size    "много"   "Неверный размер файла подкачки"
bad_value "ноль воркеров отклонён"           --fpm-children "0"       "Нужно целое число не меньше 2"
bad_value "буквы в --db-time отклонены"      --db-time      "тридцать" "Нужно число секунд"
bad_value "не-IP в --ssh-from отклонён"      --ssh-from     "мой-дом"  "Ожидается IPv4"
bad_value "отсутствующий --extra-conf отклонён" --extra-conf "/нет/такого.conf" "не найден"

# ключ командной строки должен быть важнее файла параметров
PREC="${TMP}/precedence.conf"
sed -e 's/^SITE_DOMAIN=.*/SITE_DOMAIN=prec.example.com/' \
    -e "s#^WP_PATH=.*#WP_PATH=${TMP}/site-prec#" \
    -e 's/^UPLOAD_MAX=.*/UPLOAD_MAX=8M/' \
    -e 's/^INSTALL_CACHE=.*/INSTALL_CACHE=yes/' "${TMP}/test.conf" > "$PREC"
PATH="${MOCK}:${PATH}" LOG_FILE="${TMP}/prec.log" \
  bash "${ROOT}/install.sh" -c "$PREC" -y --force --upload-max 512M --no-cache \
  > "${TMP}/prec-out.txt" 2>&1 || true
PRECINI="/etc/php/${PHPV}/fpm/conf.d/99-wordpress.ini"
check "ключ важнее файла: upload_max_filesize" "$PRECINI" "upload_max_filesize = 512M"
if grep -q "fastcgi_cache WPCACHE" /etc/nginx/sites-available/prec.example.com.conf 2>/dev/null; then
  fail "ключ важнее файла: --no-cache проигнорирован"
else
  pass "ключ важнее файла: --no-cache сработал"
fi

# ============================== файл параметров и определение дистрибутива
printf '\n\033[1mФайл параметров и определение системы\033[0m\n'

CFG_OUT="${TMP}/saved.conf"
if PATH="${MOCK}:${PATH}" LOG_FILE="${TMP}/configure.log" \
   bash "${ROOT}/install.sh" --configure "$CFG_OUT" -y --no-tui > "${TMP}/configure-out.txt" 2>&1; then
  pass "--configure отработал без установки"
else
  fail "--configure завершился с ошибкой"; tail -n 10 "${TMP}/configure-out.txt"
fi
[[ -f "$CFG_OUT" ]] && pass "файл параметров создан" || fail "файла параметров нет"
[[ "$(stat -c %a "$CFG_OUT" 2>/dev/null)" == "600" ]] && pass "файл параметров: права 600" || fail "файл параметров: неверные права"
check "файл параметров: домен"        "$CFG_OUT" "SITE_DOMAIN="
check "файл параметров: пароль админа" "$CFG_OUT" "WP_ADMIN_PASS="
check "файл параметров: лимиты PHP"    "$CFG_OUT" "MAX_INPUT_VARS="
check "файл параметров: подсказка"     "$CFG_OUT" "--configure"
if grep -q "wp-includes" "${TMP}/site-configure" 2>/dev/null; then
  fail "--configure не должен ничего устанавливать"
else
  pass "--configure ничего не установил"
fi

# правка существующего файла: меняем одно значение, остальные должны уцелеть
CFG_EDIT="${TMP}/edited.conf"
cp "$CFG_OUT" "$CFG_EDIT"
sed -i 's/^SITE_TITLE=.*/SITE_TITLE="Было"/' "$CFG_EDIT"
ORIG_PASS="$(grep '^DB_PASS=' "$CFG_EDIT")"
# ввод: Enter на домене, новое название, дальше Enter на всё остальное
# (без yes|head — они дают SIGPIPE и роняют тест целиком)
{ printf '\n'; printf 'Стало\n'; printf '\n%.0s' $(seq 1 40); } \
  | PATH="${MOCK}:${PATH}" LOG_FILE="${TMP}/edit.log" \
    bash "${ROOT}/install.sh" --configure "$CFG_EDIT" --no-tui > "${TMP}/edit-out.txt" 2>&1 || true
check "правка конфига: новое значение записано" "$CFG_EDIT" 'SITE_TITLE="Стало"'
if grep -qxF "$ORIG_PASS" "$CFG_EDIT"; then pass "правка конфига: пароль БД не потерялся"; else fail "правка конфига: пароль БД изменился"; fi

# --save-config при обычной установке
SAVED2="${TMP}/from-install.conf"
sed -e 's/^SITE_DOMAIN=.*/SITE_DOMAIN=save.example.com/' \
    -e "s#^WP_PATH=.*#WP_PATH=${TMP}/site-save#" "${TMP}/test.conf" > "${TMP}/test-save.conf"
PATH="${MOCK}:${PATH}" LOG_FILE="${TMP}/save.log" \
  bash "${ROOT}/install.sh" -c "${TMP}/test-save.conf" -y --force --save-config "$SAVED2" \
  > "${TMP}/save-out.txt" 2>&1 || true
[[ -f "$SAVED2" ]] && pass "--save-config записал файл при установке" || fail "--save-config не сработал"
check "--save-config: домен из установки" "$SAVED2" 'SITE_DOMAIN="save.example.com"'

# определение дистрибутива по подсунутому os-release
os_case() { # os_case ФАЙЛ ОЖИДАНИЕ ОПИСАНИЕ
  local out
  out="$(OS_RELEASE_FILE="$1" LOG_FILE="${TMP}/os.log" bash -c '
    set -euo pipefail
    source '"${ROOT}"'/lib/common.sh
    source '"${ROOT}"'/lib/screen.sh
    init_log; check_os' 2>&1 || true)"
  if [[ "$2" == "ok" ]]; then
    grep -q "Система:" <<< "$out" && pass "$3" || { fail "$3"; echo "$out" | head -3; }
  else
    grep -q "Поддерживаются" <<< "$out" && pass "$3" || { fail "$3"; echo "$out" | head -3; }
  fi
}
printf 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nID=debian\nVERSION_ID="12"\n' > "${TMP}/os-debian12"
printf 'PRETTY_NAME="Ubuntu 24.04.4 LTS"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' > "${TMP}/os-ubuntu"
printf 'PRETTY_NAME="Linux Mint 21"\nID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="21"\n' > "${TMP}/os-mint"
printf 'PRETTY_NAME="Fedora 40"\nID=fedora\nVERSION_ID="40"\n' > "${TMP}/os-fedora"
os_case "${TMP}/os-debian12" ok   "Debian 12 (без ID_LIKE) принимается"
os_case "${TMP}/os-ubuntu"   ok   "Ubuntu принимается"
os_case "${TMP}/os-mint"     ok   "производные от Ubuntu принимаются"
os_case "${TMP}/os-fedora"   fail "не-apt система отклоняется"

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
