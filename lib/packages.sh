#!/usr/bin/env bash
# lib/packages.sh — установка пакетов, автоопределение версий PHP и СУБД.
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

APT_UPDATED=0

apt_update() {
  [[ "$APT_UPDATED" == "1" ]] && return 0
  step "Обновление списка пакетов (apt update)"
  run apt-get update -qq || die "apt-get update завершился с ошибкой."
  APT_UPDATED=1
}

apt_install() {
  [[ $# -gt 0 ]] || return 0
  apt_update
  step "Установка: $*"
  run apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

apt_install_optional() {
  local p
  for p in "$@"; do
    if apt_candidate_exists "$p"; then
      apt_install "$p" || warn "Не удалось установить необязательный пакет $p — пропускаем."
    else
      log "[SKIP] пакет $p недоступен в репозитории"
    fi
  done
}

apt_candidate_exists() {
  local c
  c="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}')"
  [[ -n "$c" && "$c" != "(none)" ]]
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"; }

# ---------------------------------------------------------------- базовые пакеты
install_base_packages() {
  info "Установка системных пакетов"
  apt_update
  apt_install ca-certificates curl wget tar unzip sudo rsync lsb-release gnupg apt-transport-https

  install_web_server_pkg
  install_db_server_pkg
  install_php_packages
  ok "Пакеты установлены"
}

install_web_server_pkg() {
  case "$WEB_SERVER" in
    nginx)
      if pkg_installed apache2 && [[ "${FORCE:-0}" != "1" ]]; then
        warn "В системе установлен Apache — он будет остановлен, чтобы освободить порт 80."
        run systemctl stop apache2 || true
        run systemctl disable apache2 || true
      fi
      apt_install nginx
      ;;
    apache)
      if pkg_installed nginx; then
        warn "В системе установлен Nginx — он будет остановлен, чтобы освободить порт 80."
        run systemctl stop nginx || true
        run systemctl disable nginx || true
      fi
      apt_install apache2
      ;;
  esac
}

# ------------------------------------------------------------------------ СУБД
install_db_server_pkg() {
  if systemctl is-active --quiet mariadb 2>/dev/null; then
    DB_SERVICE="mariadb"; DB_INSTALLED_BEFORE=1
    ok "Обнаружена работающая MariaDB — используем её"; return 0
  fi
  if systemctl is-active --quiet mysql 2>/dev/null; then
    DB_SERVICE="mysql"; DB_INSTALLED_BEFORE=1
    ok "Обнаружен работающий MySQL — используем его"; return 0
  fi

  local target="$DB_ENGINE"
  if [[ "$target" == "auto" ]]; then
    if apt_candidate_exists mariadb-server; then target="mariadb"; else target="mysql"; fi
  fi

  if [[ "$target" == "mariadb" ]]; then
    apt_candidate_exists mariadb-server || die "Пакет mariadb-server недоступен. Попробуйте --db-engine mysql."
    apt_install mariadb-server mariadb-client
    DB_SERVICE="mariadb"
  else
    apt_candidate_exists mysql-server || die "Пакет mysql-server недоступен. Попробуйте --db-engine mariadb."
    apt_install mysql-server mysql-client
    DB_SERVICE="mysql"
  fi
  DB_INSTALLED_BEFORE=0
  ok "СУБД: $DB_SERVICE"
}

# ------------------------------------------------------------------------- PHP
# Список расширений, нужных WordPress (без префикса версии).
PHP_EXT=(fpm mysql curl gd mbstring xml zip intl bcmath soap opcache)
PHP_EXT_OPTIONAL=(imagick igbinary)

install_php_packages() {
  local prefix pkgs=() e

  if [[ "${PHP_VERSION:-auto}" == "auto" || -z "${PHP_VERSION:-}" ]]; then
    prefix="php"
  else
    prefix="php${PHP_VERSION}"
    if ! apt_candidate_exists "${prefix}-fpm"; then
      warn "PHP ${PHP_VERSION} отсутствует в подключённых репозиториях."
      if [[ "${OS_ID}" == "ubuntu" ]]; then
        if [[ "${ASSUME_YES}" == "1" ]] || confirm "Подключить репозиторий ppa:ondrej/php, чтобы получить PHP ${PHP_VERSION}?" "yes"; then
          apt_install software-properties-common
          step "Подключение ppa:ondrej/php"
          run add-apt-repository -y ppa:ondrej/php || die "Не удалось подключить ppa:ondrej/php"
          APT_UPDATED=0; apt_update
        fi
      fi
      if ! apt_candidate_exists "${prefix}-fpm"; then
        warn "PHP ${PHP_VERSION} получить не удалось — ставим версию по умолчанию из репозитория."
        prefix="php"; PHP_VERSION="auto"
      fi
    fi
  fi

  for e in "${PHP_EXT[@]}"; do
    apt_candidate_exists "${prefix}-${e}" && pkgs+=("${prefix}-${e}")
  done
  [[ ${#pkgs[@]} -gt 0 ]] || die "Не найдено ни одного пакета PHP (${prefix}-*)."
  apt_install "${pkgs[@]}"

  local opts=()
  for e in "${PHP_EXT_OPTIONAL[@]}"; do opts+=("${prefix}-${e}"); done
  apt_install_optional "${opts[@]}"
}

# Определяет PHP_VER, PHP_FPM_SERVICE, PHP_FPM_LISTEN, PHP_FPM_PASS
detect_php() {
  info "Определение версии PHP"
  local v="" d
  if [[ -n "${PHP_VERSION:-}" && "$PHP_VERSION" != "auto" && -d "/etc/php/${PHP_VERSION}/fpm" ]]; then
    v="$PHP_VERSION"
  else
    for d in $(find /etc/php -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+$' | sort -V); do
      [[ -d "/etc/php/${d}/fpm" ]] && v="$d"
    done
  fi
  [[ -n "$v" ]] || die "PHP-FPM не найден в /etc/php/*/fpm. Установка PHP не удалась."

  PHP_VER="$v"
  PHP_FPM_SERVICE="php${v}-fpm"
  service_exists "$PHP_FPM_SERVICE" || PHP_FPM_SERVICE="php-fpm"

  local listen=""
  if [[ -r "/etc/php/${v}/fpm/pool.d/www.conf" ]]; then
    listen="$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//p' "/etc/php/${v}/fpm/pool.d/www.conf" | head -n1)"
  fi
  [[ -n "$listen" ]] || listen="/run/php/php${v}-fpm.sock"
  listen="${listen%%[[:space:]]*}"

  if [[ "$listen" == /* ]]; then
    PHP_FPM_LISTEN="$listen"
    PHP_FPM_PASS="unix:${listen}"
  else
    PHP_FPM_LISTEN="$listen"
    PHP_FPM_PASS="${listen}"
  fi
  ok "PHP ${PHP_VER}, служба ${PHP_FPM_SERVICE}, сокет ${PHP_FPM_LISTEN}"
}

size_to_mb() { # 128M|1G -> 128|1024
  local v="${1:-0M}" num unit
  unit="${v: -1}"; num="${v%[MG]}"
  [[ "$unit" == "G" ]] && num=$(( num * 1024 ))
  printf '%s' "$num"
}

double_size() { # 128M -> 256M
  local v="$1" num unit
  unit="${v: -1}"; num="${v%[MG]}"
  [[ "$unit" == "G" ]] && num=$(( num * 1024 ))
  printf '%sM' "$(( num * 2 ))"
}

configure_php() {
  info "Настройка PHP для WordPress"
  local post_max mem_num up_num
  post_max="$(double_size "$UPLOAD_MAX")"

  # memory_limit не может быть меньше post_max_size
  mem_num="$(size_to_mb "${PHP_MEMORY_LIMIT:-256M}")"
  up_num="$(size_to_mb "$post_max")"
  (( mem_num < up_num )) && mem_num="$up_num"

  local dir ini
  for dir in "/etc/php/${PHP_VER}/fpm" "/etc/php/${PHP_VER}/cli"; do
    [[ -d "${dir}/conf.d" ]] || continue
    ini="${dir}/conf.d/99-wordpress.ini"
    cat > "$ini" <<INI
; Создано wp-autoinstall — параметры PHP для WordPress
upload_max_filesize = ${UPLOAD_MAX}
post_max_size = ${post_max}
memory_limit = ${mem_num}M
max_execution_time = ${MAX_EXEC_TIME:-300}
max_input_time = ${MAX_EXEC_TIME:-300}
max_input_vars = ${MAX_INPUT_VARS:-3000}
date.timezone = UTC
cgi.fix_pathinfo = 0
expose_php = Off
INI
    ok "Записан ${ini}"
  done
  ok "upload_max_filesize=${UPLOAD_MAX}, post_max_size=${post_max}, memory_limit=${mem_num}M, max_input_vars=${MAX_INPUT_VARS:-3000}"
  svc_restart "$PHP_FPM_SERVICE"
}
