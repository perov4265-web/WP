#!/usr/bin/env bash
# lib/prompts.sh — аргументы командной строки, конфиг-файл и опрос параметров.
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях

usage() {
  cat <<'USAGE'
wp-autoinstall — установка WordPress на Ubuntu и Debian одной командой.

ИСПОЛЬЗОВАНИЕ
  sudo ./install.sh [опции]

ОСНОВНЫЕ ОПЦИИ
  -c, --config ФАЙЛ        Взять параметры из файла (см. config.example.conf)
  -y, --yes                Не задавать вопросов: брать значения из файла/опций,
                           недостающие пароли сгенерировать
  -v, --verbose            Показывать вывод apt и прочих команд
      --tui / --no-tui     Принудительно включить/выключить псевдографический
                           интерфейс вопросов (по умолчанию — автоматически)
      --plain              Не рисовать экран установки с прогресс-баром,
                           выводить ход работы обычным списком строк
      --skip-os-check      Не проверять дистрибутив (для apt-совместимых систем,
                           которых скрипт не знает)

РАБОТА С ФАЙЛОМ ПАРАМЕТРОВ
      --save-config ФАЙЛ   Записать ответы мастера в файл и продолжить установку
      --configure [ФАЙЛ]   Только пройти мастер и сохранить ответы, ничего не
                           устанавливая. Если файл существует, его значения
                           подставляются как ответы по умолчанию — так параметры
                           правятся пошагово, без nano и vim
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
      --cache / --no-cache             Кэш готовых страниц в nginx (fastcgi_cache)
      --swap / --no-swap               Файл подкачки, если его нет
      --swap-size РАЗМЕР               Размер файла подкачки (по умолчанию 2G)
      --force                          Перезаписывать существующий сайт/БД без вопросов

УСТОЙЧИВОСТЬ ПОД НАГРУЗКОЙ
      --fpm-children N     Число воркеров PHP-FPM (по умолчанию — от объёма RAM)
      --fpm-timeout СЕК    Через сколько обрывается зависший запрос PHP
      --db-time СЕК        Через сколько обрывается тяжёлый SQL-запрос (30)
      --search-rate ТЕМП   Лимит на поиск по сайту, формат nginx (20r/m)
      --extra-conf ФАЙЛ    Подключить свои правила веб-сервера (редиректы,
                           заглушки старых адресов) в конфиг сайта
      --ssh-from АДРЕС     Открыть SSH только с этого IP (иначе с любого)
      --no-robots          Не создавать robots.txt
      --debug-wp           Включить журнал ошибок WordPress (WP_DEBUG_LOG)

ПРИМЕРЫ
  sudo ./install.sh
  sudo ./install.sh -c my-site.conf -y
  sudo ./install.sh --domain shop.ru --title "Мой магазин" --email me@shop.ru \
       --upload-max 256M --max-input-vars 5000 --ssl -y
USAGE
}

# Ключи, заданные в командной строке. Файл параметров их не перебивает:
# опция всегда важнее файла, иначе `install.sh -c site.conf --ssl` молча
# игнорировал бы --ssl, если в файле стоит INSTALL_SSL=no.
CLI_KEYS=""

set_opt() {
  printf -v "$1" '%s' "$2"
  CLI_KEYS+=" $1"
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
      --plain)        PLAIN_OUTPUT=1; shift ;;
      --skip-os-check) SKIP_OS_CHECK=1; shift ;;
      --save-config)  SAVE_CONFIG="${2:?--save-config требует путь к файлу}"; shift 2 ;;
      --save-config=*) SAVE_CONFIG="${1#*=}"; shift ;;
      --configure)
        CONFIGURE_ONLY=1
        if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
          SAVE_CONFIG="$2"; [[ -r "$2" ]] && CONFIG_FILE="$2"
          shift 2
        else
          shift
        fi
        ;;
      --configure=*)
        CONFIGURE_ONLY=1
        SAVE_CONFIG="${1#*=}"
        [[ -r "$SAVE_CONFIG" ]] && CONFIG_FILE="$SAVE_CONFIG"
        shift ;;
      --no-tui)       UI_MODE=text; shift ;;
      --force)        set_opt FORCE 1; shift ;;
      --domain)       set_opt SITE_DOMAIN "${2:?}"; shift 2 ;;
      --title)        set_opt SITE_TITLE "${2:?}"; shift 2 ;;
      --locale)       set_opt WP_LOCALE "${2:?}"; shift 2 ;;
      --db-name)      set_opt DB_NAME "${2:?}"; shift 2 ;;
      --db-user)      set_opt DB_USER "${2:?}"; shift 2 ;;
      --db-pass)      set_opt DB_PASS "${2:?}"; shift 2 ;;
      --db-root-pass) set_opt DB_ROOT_PASS "${2:?}"; shift 2 ;;
      --admin-user)   set_opt WP_ADMIN_USER "${2:?}"; shift 2 ;;
      --admin-pass)   set_opt WP_ADMIN_PASS "${2:?}"; shift 2 ;;
      --email)        set_opt WP_EMAIL "${2:?}"; shift 2 ;;
      --web-server)   set_opt WEB_SERVER "${2:?}"; shift 2 ;;
      --php-version)  set_opt PHP_VERSION "${2:?}"; shift 2 ;;
      --db-engine)    set_opt DB_ENGINE "${2:?}"; shift 2 ;;
      --upload-max)   set_opt UPLOAD_MAX "${2:?}"; shift 2 ;;
      --max-input-vars) set_opt MAX_INPUT_VARS "${2:?}"; shift 2 ;;
      --memory-limit) set_opt PHP_MEMORY_LIMIT "${2:?}"; shift 2 ;;
      --max-exec-time) set_opt MAX_EXEC_TIME "${2:?}"; shift 2 ;;
      --prefix)       set_opt TABLE_PREFIX "${2:?}"; shift 2 ;;
      --path)         set_opt WP_PATH "${2:?}"; shift 2 ;;
      --phpmyadmin)   set_opt INSTALL_PMA yes; shift ;;
      --no-phpmyadmin) set_opt INSTALL_PMA no; shift ;;
      --ssl)          set_opt INSTALL_SSL yes; shift ;;
      --no-ssl)       set_opt INSTALL_SSL no; shift ;;
      --firewall)     set_opt INSTALL_FIREWALL yes; shift ;;
      --no-firewall)  set_opt INSTALL_FIREWALL no; shift ;;
      --cache)        set_opt INSTALL_CACHE yes; shift ;;
      --no-cache)     set_opt INSTALL_CACHE no; shift ;;
      --swap)         set_opt SETUP_SWAP yes; shift ;;
      --no-swap)      set_opt SETUP_SWAP no; shift ;;
      --swap-size)    set_opt SWAP_SIZE "${2:?}"; shift 2 ;;
      --no-robots)    set_opt CREATE_ROBOTS no; shift ;;
      --debug-wp)     set_opt WP_DEBUG_MODE yes; shift ;;
      --search-rate)  set_opt SEARCH_RATE "${2:?}"; shift 2 ;;
      --ssh-from)     set_opt SSH_ALLOW_FROM "${2:?}"; shift 2 ;;
      --extra-conf)   set_opt NGINX_EXTRA_CONF "${2:?}"; shift 2 ;;
      --fpm-children) set_opt FPM_MAX_CHILDREN "${2:?}"; shift 2 ;;
      --fpm-timeout)  set_opt FPM_TIMEOUT "${2:?}"; shift 2 ;;
      --db-time)      set_opt DB_MAX_STATEMENT_TIME "${2:?}"; shift 2 ;;
      *) printf 'Неизвестная опция: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

# Разрешённые ключи конфигурационного файла
CONFIG_KEYS="SITE_DOMAIN SITE_TITLE WP_LOCALE WP_PATH WP_ADMIN_USER WP_ADMIN_PASS WP_EMAIL \
DB_NAME DB_USER DB_PASS DB_ROOT_PASS DB_ENGINE TABLE_PREFIX WEB_SERVER PHP_VERSION \
UPLOAD_MAX MAX_INPUT_VARS PHP_MEMORY_LIMIT MAX_EXEC_TIME \
INSTALL_PMA INSTALL_SSL INSTALL_FIREWALL INSTALL_CACHE SETUP_SWAP SWAP_SIZE \
CREATE_ROBOTS WP_DEBUG_MODE SEARCH_RATE SSH_ALLOW_FROM NGINX_EXTRA_CONF \
FPM_MAX_CHILDREN FPM_TIMEOUT DB_MAX_STATEMENT_TIME DB_BUFFER_POOL_MB \
FORCE VERBOSE"

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
      # Комментарий обрезаем только если решётке предшествует пробел:
      # иначе пароль вида Xq7#mR2v превратился бы в Xq7.
      if [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
    fi
    if [[ " ${CONFIG_KEYS} " != *" ${key} "* ]]; then
      warn "Строка ${lineno}: неизвестный параметр ${key} — пропущен."
      continue
    fi
    # ключ командной строки важнее файла
    if [[ " ${CLI_KEYS:-} " == *" ${key} "* ]]; then
      log "[CONF] ${key}: значение из файла игнорируется, задано ключом командной строки"
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
  local def_email="admin@${SITE_DOMAIN}"
  # на IP-адресе admin@203.0.113.10 — не адрес, подставлять его бессмысленно
  is_ip "$SITE_DOMAIN" && def_email="admin@example.com"
  ui_input  WP_EMAIL "Email администратора (нужен для восстановления пароля):" "$def_email" v_email

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
  local -a comps=(
    "INSTALL_PMA|phpMyAdmin|веб-интерфейс к базе данных|off"
    "INSTALL_SSL|SSL|сертификат Let's Encrypt, нужен домен|${ssl_state}"
    "INSTALL_FIREWALL|Брандмауэр|UFW и fail2ban против подбора паролей|off"
  )
  # кэш страниц умеет только nginx
  [[ "$WEB_SERVER" == "nginx" ]] && \
    comps+=("INSTALL_CACHE|Кэш|отдавать ботам готовый HTML мимо PHP|off")
  # подкачку предлагаем, только если её ещё нет
  if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    comps+=("SETUP_SWAP|Подкачка|файл подкачки ${SWAP_SIZE:-2G}, страховка от нехватки памяти|on")
  fi
  ui_checklist "Дополнительные компоненты — что установить?" "${comps[@]}"

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
  INSTALL_CACHE="${INSTALL_CACHE:-no}"
  SETUP_SWAP="${SETUP_SWAP:-no}"
}

# Значение для файла параметров: всегда в двойных кавычках, переводы строк убираем
cfg_quote() {
  local v="$1"
  v="${v//$'\n'/ }"
  v="${v//$'\r'/}"
  printf '"%s"' "$v"
}

# save_config_file ПУТЬ — записывает ответы мастера в файл параметров (права 600)
save_config_file() {
  local path="$1" dir
  dir="$(dirname "$path")"
  [[ -d "$dir" ]] || die "Каталог для файла параметров не найден: ${dir}"

  install -m 600 /dev/null "$path" 2>/dev/null || {
    : > "$path" && chmod 600 "$path"
  } || die "Не удалось создать файл параметров: ${path}"

  {
    printf '# Файл параметров wp-autoinstall\n'
    printf '# Создан %s по ответам мастера установки.\n' "$(date '+%F %T')"
    printf '#\n'
    printf '# ВНИМАНИЕ: здесь лежат пароли. Права на файл — 600, не копируйте его\n'
    printf '# в общедоступные каталоги и не кладите в git.\n'
    printf '#\n'
    printf '# Повторить установку с этими параметрами:\n'
    printf '#     sudo ./install.sh -c %s --yes\n' "$path"
    printf '#\n'
    printf '# Изменить параметры пошагово, без правки файла руками:\n'
    printf '#     sudo ./install.sh --configure %s\n' "$path"
    printf '\n'
    printf '# ---------- сайт ----------\n'
    printf 'SITE_DOMAIN=%s\n'      "$(cfg_quote "$SITE_DOMAIN")"
    printf 'SITE_TITLE=%s\n'       "$(cfg_quote "$SITE_TITLE")"
    printf 'WP_LOCALE=%s\n'        "$(cfg_quote "$WP_LOCALE")"
    printf 'WP_PATH=%s\n'          "$(cfg_quote "${WP_PATH:-/var/www/${SITE_DOMAIN}}")"
    printf '\n# ---------- администратор WordPress ----------\n'
    printf 'WP_ADMIN_USER=%s\n'    "$(cfg_quote "$WP_ADMIN_USER")"
    printf 'WP_ADMIN_PASS=%s\n'    "$(cfg_quote "$WP_ADMIN_PASS")"
    printf 'WP_EMAIL=%s\n'         "$(cfg_quote "$WP_EMAIL")"
    printf '\n# ---------- база данных ----------\n'
    printf 'DB_NAME=%s\n'          "$(cfg_quote "$DB_NAME")"
    printf 'DB_USER=%s\n'          "$(cfg_quote "$DB_USER")"
    printf 'DB_PASS=%s\n'          "$(cfg_quote "$DB_PASS")"
    printf 'TABLE_PREFIX=%s\n'     "$(cfg_quote "$TABLE_PREFIX")"
    printf 'DB_ENGINE=%s\n'        "$(cfg_quote "$DB_ENGINE")"
    printf '\n# ---------- окружение ----------\n'
    printf 'WEB_SERVER=%s\n'       "$(cfg_quote "$WEB_SERVER")"
    printf 'PHP_VERSION=%s\n'      "$(cfg_quote "$PHP_VERSION")"
    printf '\n# ---------- параметры PHP ----------\n'
    printf 'UPLOAD_MAX=%s\n'       "$(cfg_quote "$UPLOAD_MAX")"
    printf 'MAX_INPUT_VARS=%s\n'   "$(cfg_quote "$MAX_INPUT_VARS")"
    printf 'PHP_MEMORY_LIMIT=%s\n' "$(cfg_quote "$PHP_MEMORY_LIMIT")"
    printf 'MAX_EXEC_TIME=%s\n'    "$(cfg_quote "$MAX_EXEC_TIME")"
    printf '\n# ---------- дополнительные компоненты ----------\n'
    printf 'INSTALL_PMA=%s\n'      "$(cfg_quote "$INSTALL_PMA")"
    printf 'INSTALL_SSL=%s\n'      "$(cfg_quote "$INSTALL_SSL")"
    printf 'INSTALL_FIREWALL=%s\n' "$(cfg_quote "$INSTALL_FIREWALL")"
    printf 'INSTALL_CACHE=%s\n'    "$(cfg_quote "$INSTALL_CACHE")"
    printf 'SETUP_SWAP=%s\n'       "$(cfg_quote "$SETUP_SWAP")"
    printf 'SWAP_SIZE=%s\n'        "$(cfg_quote "${SWAP_SIZE:-2G}")"
    printf 'CREATE_ROBOTS=%s\n'    "$(cfg_quote "${CREATE_ROBOTS:-yes}")"
    printf '\n# ---------- устойчивость под нагрузкой ----------\n'
    printf 'SEARCH_RATE=%s\n'            "$(cfg_quote "${SEARCH_RATE:-20r/m}")"
    printf 'DB_MAX_STATEMENT_TIME=%s\n'  "$(cfg_quote "${DB_MAX_STATEMENT_TIME:-30}")"
    printf '# FPM_MAX_CHILDREN=  # пусто — считается от объёма памяти\n'
    printf '# FPM_TIMEOUT=       # пусто — max_execution_time + 30 с\n'
    printf '# NGINX_EXTRA_CONF=  # свой файл правил веб-сервера\n'
    printf '# SSH_ALLOW_FROM=    # открыть SSH только с этого адреса\n'
  } >> "$path"

  ok "Параметры сохранены: ${path} (права 600)"
}

# Спросить про сохранение и записать файл
maybe_save_config() {
  if [[ -n "${SAVE_CONFIG:-}" ]]; then
    save_config_file "$SAVE_CONFIG"
    return 0
  fi
  [[ "$ASSUME_YES" == "1" ]] && return 0

  local answer=""
  ui_yesno answer "Сохранить ответы в файл параметров? Пригодится, чтобы повторить установку или поменять настройки потом — пошагово, без правки файла руками." "yes"
  [[ "$answer" == "yes" ]] || return 0

  SAVE_CONFIG="${SCRIPT_DIR:-.}/wp-${SITE_DOMAIN}.conf"
  save_config_file "$SAVE_CONFIG"
}

# Проверка значений, которые попадают прямо в конфигурацию сервисов.
# Их можно задать и ключом, и файлом параметров, минуя мастер, поэтому проверяем
# отдельно: неверное значение здесь — это упавший nginx или не вставшая СУБД.
validate_tuning_params() {
  local v

  v="${SEARCH_RATE:-20r/m}"
  [[ "$v" =~ ^[0-9]+r/[sm]$ ]] || die "Неверный формат --search-rate: '${v}'. Ожидается вид 20r/m или 5r/s."

  v="${SWAP_SIZE:-2G}"
  [[ "$v" =~ ^[0-9]+[MG]$ ]] || die "Неверный размер файла подкачки: '${v}'. Ожидается вид 2G или 512M."

  if [[ -n "${FPM_MAX_CHILDREN:-}" ]]; then
    if ! [[ "$FPM_MAX_CHILDREN" =~ ^[0-9]+$ ]] || (( FPM_MAX_CHILDREN < 2 )); then
      die "Неверное число воркеров PHP-FPM: '${FPM_MAX_CHILDREN}'. Нужно целое число не меньше 2."
    fi
  fi
  if [[ -n "${FPM_TIMEOUT:-}" ]]; then
    if ! [[ "$FPM_TIMEOUT" =~ ^[0-9]+$ ]] || (( FPM_TIMEOUT < 10 )); then
      die "Неверный таймаут PHP-FPM: '${FPM_TIMEOUT}'. Нужно число секунд не меньше 10."
    fi
  fi
  if [[ -n "${DB_MAX_STATEMENT_TIME:-}" ]]; then
    if ! [[ "$DB_MAX_STATEMENT_TIME" =~ ^[0-9]+$ ]] || (( DB_MAX_STATEMENT_TIME < 1 )); then
      die "Неверный таймаут SQL-запроса: '${DB_MAX_STATEMENT_TIME}'. Нужно число секунд."
    fi
  fi
  if [[ -n "${DB_BUFFER_POOL_MB:-}" ]]; then
    [[ "$DB_BUFFER_POOL_MB" =~ ^[0-9]+$ ]] \
      || die "Неверный размер буфера СУБД: '${DB_BUFFER_POOL_MB}'. Нужно число мегабайт."
  fi
  if [[ -n "${SSH_ALLOW_FROM:-}" ]]; then
    [[ "$SSH_ALLOW_FROM" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
      || die "Неверный адрес для --ssh-from: '${SSH_ALLOW_FROM}'. Ожидается IPv4 или подсеть, например 203.0.113.5 или 203.0.113.0/24."
  fi
  if [[ -n "${NGINX_EXTRA_CONF:-}" && ! -r "$NGINX_EXTRA_CONF" ]]; then
    die "Файл своих правил веб-сервера не найден или недоступен: ${NGINX_EXTRA_CONF}"
  fi
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
  База данных ........... ${DB_NAME}
  Пользователь БД ....... ${DB_USER} (префикс ${TABLE_PREFIX})
  Администратор ......... ${WP_ADMIN_USER} <${WP_EMAIL}>

  upload_max_filesize ... ${UPLOAD_MAX}
  max_input_vars ........ ${MAX_INPUT_VARS}
  memory_limit .......... ${PHP_MEMORY_LIMIT}
  max_execution_time .... ${MAX_EXEC_TIME}

  phpMyAdmin ............ ${INSTALL_PMA}
  SSL (Let's Encrypt) ... ${INSTALL_SSL}
  UFW + fail2ban ........ ${INSTALL_FIREWALL}
  Кэш страниц ........... ${INSTALL_CACHE}
  Файл подкачки ......... ${SETUP_SWAP}
SUM
)"
  ui_confirm_summary "$text"
  log "$text"
}
