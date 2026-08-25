#!/usr/bin/env bash
# lib/prompts.sh — аргументы командной строки, конфиг-файл и опрос параметров.
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях

usage() {
  cat <<'USAGE'
wp-autoinstall — установка WordPress на Ubuntu одной командой.

ИСПОЛЬЗОВАНИЕ
  sudo ./install.sh [опции]

ОСНОВНЫЕ ОПЦИИ
  -c, --config ФАЙЛ        Взять параметры из файла (см. config.example.conf)
  -y, --yes                Не задавать вопросов: брать значения из файла/опций,
                           недостающие пароли сгенерировать
  -v, --verbose            Показывать вывод apt и прочих команд
      --tui / --no-tui     Принудительно включить/выключить псевдографический
                           интерфейс (по умолчанию — автоматически)
  -h, --help               Показать эту справку

ПАРАМЕТРЫ САЙТА (что не задано — скрипт спросит)
      --domain ДОМЕН       Домен или IP сайта (example.com)
      --title "НАЗВАНИЕ"   Название сайта
      --locale ЛОКАЛЬ      Язык WordPress (ru_RU, en_US, ...)
      --db-name ИМЯ        Имя базы данных
      --db-user ИМЯ        Пользователь базы данных
      --db-pass ПАРОЛЬ     Пароль пользователя базы данных
      --db-root-pass П     Пароль root для MySQL/MariaDB (если требуется)
      --admin-user ИМЯ     Логин администратора WordPress
      --admin-pass ПАРОЛЬ  Пароль администратора WordPress
      --email EMAIL        Email администратора
      --web-server ИМЯ     nginx | apache
      --php-version ВЕР    Версия PHP (8.3) или auto — по умолчанию auto
      --db-engine ИМЯ      mariadb | mysql | auto
      --prefix ПРЕФИКС     Префикс таблиц БД (по умолчанию wp_)
      --path ПУТЬ          Каталог сайта (по умолчанию /var/www/ДОМЕН)

ПАРАМЕТРЫ PHP (выбираются из списка или задаются вручную)
      --upload-max РАЗМЕР      upload_max_filesize: 8M 16M 32M 64M 128M 256M 512M 1G
      --max-input-vars ЧИСЛО   max_input_vars: 1000 3000 5000 10000 20000
      --memory-limit РАЗМЕР    memory_limit: 128M 256M 512M 768M 1G
      --max-exec-time СЕК      max_execution_time: 30 60 120 300 600

ДОПОЛНИТЕЛЬНЫЕ КОМПОНЕНТЫ
      --phpmyadmin / --no-phpmyadmin   phpMyAdmin в /phpmyadmin/
      --ssl / --no-ssl                 Сертификат Let's Encrypt (нужен домен)
      --firewall / --no-firewall       UFW + fail2ban
      --force                          Перезаписывать существующий сайт/БД без вопросов

ПРИМЕРЫ
  sudo ./install.sh
  sudo ./install.sh -c my-site.conf -y
  sudo ./install.sh --domain shop.ru --title "Мой магазин" --email me@shop.ru \
       --upload-max 256M --max-input-vars 5000 --ssl -y
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)      usage; exit 0 ;;
      -c|--config)    CONFIG_FILE="${2:?--config требует путь к файлу}"; shift 2 ;;
      --config=*)     CONFIG_FILE="${1#*=}"; shift ;;
      -y|--yes)       ASSUME_YES=1; shift ;;
      -v|--verbose)   VERBOSE=1; shift ;;
      --tui)          UI_MODE=tui; shift ;;
      --no-tui)       UI_MODE=text; shift ;;
      --force)        FORCE=1; shift ;;
      --domain)       SITE_DOMAIN="${2:?}"; shift 2 ;;
      --title)        SITE_TITLE="${2:?}"; shift 2 ;;
      --locale)       WP_LOCALE="${2:?}"; shift 2 ;;
      --db-name)      DB_NAME="${2:?}"; shift 2 ;;
      --db-user)      DB_USER="${2:?}"; shift 2 ;;
      --db-pass)      DB_PASS="${2:?}"; shift 2 ;;
      --db-root-pass) DB_ROOT_PASS="${2:?}"; shift 2 ;;
      --admin-user)   WP_ADMIN_USER="${2:?}"; shift 2 ;;
      --admin-pass)   WP_ADMIN_PASS="${2:?}"; shift 2 ;;
      --email)        WP_EMAIL="${2:?}"; shift 2 ;;
      --web-server)   WEB_SERVER="${2:?}"; shift 2 ;;
      --php-version)  PHP_VERSION="${2:?}"; shift 2 ;;
      --db-engine)    DB_ENGINE="${2:?}"; shift 2 ;;
      --upload-max)   UPLOAD_MAX="${2:?}"; shift 2 ;;
      --max-input-vars) MAX_INPUT_VARS="${2:?}"; shift 2 ;;
      --memory-limit) PHP_MEMORY_LIMIT="${2:?}"; shift 2 ;;
      --max-exec-time) MAX_EXEC_TIME="${2:?}"; shift 2 ;;
      --prefix)       TABLE_PREFIX="${2:?}"; shift 2 ;;
      --path)         WP_PATH="${2:?}"; shift 2 ;;
      --phpmyadmin)   INSTALL_PMA=yes; shift ;;
      --no-phpmyadmin) INSTALL_PMA=no; shift ;;
      --ssl)          INSTALL_SSL=yes; shift ;;
      --no-ssl)       INSTALL_SSL=no; shift ;;
      --firewall)     INSTALL_FIREWALL=yes; shift ;;
      --no-firewall)  INSTALL_FIREWALL=no; shift ;;
      *) printf 'Неизвестная опция: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

# Разрешённые ключи конфигурационного файла
CONFIG_KEYS="SITE_DOMAIN SITE_TITLE WP_LOCALE WP_PATH WP_ADMIN_USER WP_ADMIN_PASS WP_EMAIL \
DB_NAME DB_USER DB_PASS DB_ROOT_PASS DB_ENGINE TABLE_PREFIX WEB_SERVER PHP_VERSION \
UPLOAD_MAX MAX_INPUT_VARS PHP_MEMORY_LIMIT MAX_EXEC_TIME \
INSTALL_PMA INSTALL_SSL INSTALL_FIREWALL FORCE VERBOSE"

# Читаем файл построчно (без выполнения кода): КЛЮЧ=значение, кавычки необязательны.
load_config() {
  [[ -n "${CONFIG_FILE:-}" ]] || return 0
  [[ -r "$CONFIG_FILE" ]] || die "Файл конфигурации не найден: $CONFIG_FILE"

  local line key value lineno=0 count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$(( lineno + 1 ))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      die "Строка ${lineno} в ${CONFIG_FILE} не похожа на КЛЮЧ=значение: ${line}"
    fi
    key="${BASH_REMATCH[1]^^}"
    value="${BASH_REMATCH[2]}"
    # убираем комментарий в конце строки только у значений без кавычек
    if [[ "$value" =~ ^[[:space:]]*\"(.*)\"[[:space:]]*$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^[[:space:]]*\'(.*)\'[[:space:]]*$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value="${value%%#*}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
    fi
    if [[ " ${CONFIG_KEYS} " != *" ${key} "* ]]; then
      warn "Строка ${lineno}: неизвестный параметр ${key} — пропущен."
      continue
    fi
    [[ -z "$value" ]] && continue
    printf -v "$key" '%s' "$value"
    count=$(( count + 1 ))
  done < "$CONFIG_FILE"
  ok "Загружено параметров из ${CONFIG_FILE}: ${count}"
}

v_webserver() {
  case "${1,,}" in nginx|apache) return 0 ;; esac
  echo "допустимо: nginx или apache"; return 1
}

v_dbengine() {
  case "${1,,}" in mariadb|mysql|auto) return 0 ;; esac
  echo "допустимо: mariadb, mysql или auto"; return 1
}

v_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )) && return 0
  echo "введите целое положительное число"; return 1
}

collect_params() {
  ui_welcome

  local def_domain; def_domain="$(detect_public_ip)"
  ui_input SITE_DOMAIN "Домен или IP-адрес сайта:" "${def_domain:-example.com}" v_host
  ui_input SITE_TITLE  "Название сайта (заголовок WordPress):" "Мой сайт" v_notempty

  ui_menu WP_LOCALE "Язык WordPress:" "ru_RU" v_notempty \
    "ru_RU|Русский" "en_US|English (US)" "uk|Українська" "kk|Қазақша" \
    "de_DE|Deutsch" "fr_FR|Français" "es_ES|Español"

  ui_input  WP_ADMIN_USER "Логин администратора WordPress:" "admin" v_notempty
  ui_secret WP_ADMIN_PASS "Пароль администратора WordPress:" v_wppass
  ui_input  WP_EMAIL "Email администратора (нужен для восстановления пароля):" "admin@${SITE_DOMAIN}" v_email

  ui_input  DB_NAME "Имя базы данных:" "wp_$(rand_suffix 6)" v_ident
  ui_input  DB_USER "Пользователь базы данных:" "wpuser_$(rand_suffix 4)" v_ident
  ui_secret DB_PASS "Пароль пользователя базы данных:" v_dbpass
  ui_input  TABLE_PREFIX "Префикс таблиц базы данных:" "wp_" v_notempty

  ui_menu WEB_SERVER "Веб-сервер:" "nginx" v_webserver \
    "nginx|Nginx + PHP-FPM (рекомендуется)" "apache|Apache 2 + PHP-FPM"

  ui_menu DB_ENGINE "Система управления базами данных:" "auto" v_dbengine \
    "auto|Выбрать автоматически" "mariadb|MariaDB" "mysql|MySQL"

  ui_menu PHP_VERSION "Версия PHP:" "auto" v_phpver \
    "auto|Версия из репозитория системы" "8.4|PHP 8.4" "8.3|PHP 8.3" \
    "8.2|PHP 8.2" "8.1|PHP 8.1" "7.4|PHP 7.4 (устаревшая)"

  ui_menu UPLOAD_MAX "Максимальный размер загружаемого файла (upload_max_filesize):" "128M" v_size \
    "8M|минимальный" "16M|" "32M|" "64M|" "128M|рекомендуется" "256M|" "512M|" "1G|для видео и больших архивов"

  ui_menu MAX_INPUT_VARS "Максимальное число переменных формы (max_input_vars):" "3000" v_int \
    "1000|значение PHP по умолчанию" "3000|рекомендуется для WordPress" "5000|тяжёлые темы и конструкторы" \
    "10000|WooCommerce, большие меню" "20000|максимум"

  ui_menu PHP_MEMORY_LIMIT "Лимит памяти PHP (memory_limit):" "256M" v_size \
    "128M|минимум для WordPress" "256M|рекомендуется" "512M|магазины и конструкторы" "768M|" "1G|максимум"

  ui_menu MAX_EXEC_TIME "Максимальное время выполнения скрипта, сек (max_execution_time):" "300" v_int \
    "30|значение PHP по умолчанию" "60|" "120|" "300|рекомендуется" "600|импорт больших баз"

  local ssl_state="off"
  ui_checklist "Дополнительные компоненты — что установить?" \
    "INSTALL_PMA|phpMyAdmin (веб-интерфейс к базе данных)|off" \
    "INSTALL_SSL|SSL-сертификат Let's Encrypt (нужен домен)|${ssl_state}" \
    "INSTALL_FIREWALL|UFW + fail2ban (брандмауэр и защита от подбора паролей)|off"

  if is_ip "$SITE_DOMAIN" && [[ "${INSTALL_SSL:-no}" == "yes" ]]; then
    warn "Let's Encrypt не выдаёт сертификаты на IP-адрес — SSL будет пропущен."
    INSTALL_SSL=no
  fi

  WP_PATH="${WP_PATH:-/var/www/${SITE_DOMAIN}}"
  WEB_SERVER="${WEB_SERVER,,}"
  DB_ENGINE="${DB_ENGINE,,}"
  INSTALL_PMA="${INSTALL_PMA:-no}"
  INSTALL_SSL="${INSTALL_SSL:-no}"
  INSTALL_FIREWALL="${INSTALL_FIREWALL:-no}"
}

confirm_params() {
  local text
  text="$(cat <<SUM
Проверьте параметры установки:

  Сайт .................. ${SITE_DOMAIN}
  Название .............. ${SITE_TITLE}
  Каталог ............... ${WP_PATH}
  Язык .................. ${WP_LOCALE}
  Веб-сервер ............ ${WEB_SERVER}
  СУБД .................. ${DB_ENGINE}
  Версия PHP ............ ${PHP_VERSION}
  База данных ........... ${DB_NAME} (пользователь ${DB_USER}, префикс ${TABLE_PREFIX})
  Администратор ......... ${WP_ADMIN_USER} <${WP_EMAIL}>

  upload_max_filesize ... ${UPLOAD_MAX}
  max_input_vars ........ ${MAX_INPUT_VARS}
  memory_limit .......... ${PHP_MEMORY_LIMIT}
  max_execution_time .... ${MAX_EXEC_TIME}

  phpMyAdmin ............ ${INSTALL_PMA}
  SSL (Let's Encrypt) ... ${INSTALL_SSL}
  UFW + fail2ban ........ ${INSTALL_FIREWALL}
SUM
)"
  ui_confirm_summary "$text"
  log "$text"
}
