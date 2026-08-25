#!/usr/bin/env bash
# shellcheck disable=SC2034  # переменные используются в подключаемых модулях
#
# wp-autoinstall — установка WordPress на Ubuntu одной командой.
#
#   git clone https://github.com/<user>/wp-autoinstall.git
#   cd wp-autoinstall
#   sudo ./install.sh
#
# Скрипт спросит параметры сайта (домен, название, базу данных, пароли, email),
# установит веб-сервер, PHP, MariaDB/MySQL и полностью настроенный WordPress.
#
# Лицензия: MIT
#
set -euo pipefail

VERSION="1.1.0"

# Рамки и выравнивание требуют UTF-8: если локаль не юникодная, переключаемся на
# C.UTF-8 (есть в любой Ubuntu) — иначе кириллица считается по байтам и «едет».
if ! locale charmap 2>/dev/null | grep -qi 'utf-\?8'; then
  if locale -a 2>/dev/null | grep -qix 'C\.UTF-\?8'; then
    export LC_ALL=C.UTF-8 LANG=C.UTF-8
  fi
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ---- значения по умолчанию (переопределяются конфигом, опциями и вопросами) ----
CONFIG_FILE="${CONFIG_FILE:-}"
ASSUME_YES="${ASSUME_YES:-0}"
VERBOSE="${VERBOSE:-0}"
FORCE="${FORCE:-0}"
UI_MODE="${UI_MODE:-auto}"
PLAIN_OUTPUT="${PLAIN_OUTPUT:-0}"
LOG_FILE="${LOG_FILE:-/var/log/wp-autoinstall.log}"

SITE_DOMAIN="${SITE_DOMAIN:-}"
SITE_TITLE="${SITE_TITLE:-}"
WP_LOCALE="${WP_LOCALE:-}"
WP_PATH="${WP_PATH:-}"
WP_ADMIN_USER="${WP_ADMIN_USER:-}"
WP_ADMIN_PASS="${WP_ADMIN_PASS:-}"
WP_EMAIL="${WP_EMAIL:-}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"
DB_ENGINE="${DB_ENGINE:-}"
DB_SERVICE="${DB_SERVICE:-}"
TABLE_PREFIX="${TABLE_PREFIX:-}"
WEB_SERVER="${WEB_SERVER:-}"
PHP_VERSION="${PHP_VERSION:-}"
UPLOAD_MAX="${UPLOAD_MAX:-}"
MAX_INPUT_VARS="${MAX_INPUT_VARS:-}"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-}"
MAX_EXEC_TIME="${MAX_EXEC_TIME:-}"
INSTALL_PMA="${INSTALL_PMA:-}"
INSTALL_SSL="${INSTALL_SSL:-}"
INSTALL_FIREWALL="${INSTALL_FIREWALL:-}"
WP_CLI_OK=0
CRED_FILE=""

for f in common.sh screen.sh ui.sh prompts.sh packages.sh database.sh wordpress.sh webserver.sh extras.sh; do
  [[ -r "${LIB_DIR}/${f}" ]] || { echo "Не найден модуль ${LIB_DIR}/${f}" >&2; exit 1; }
  # shellcheck source=/dev/null
  # shellcheck disable=SC1090,SC1091
  . "${LIB_DIR}/${f}"
done

cleanup_on_exit() {
  declare -F screen_restore >/dev/null && screen_restore
  rm -f "/tmp/wp-install-$$.php"
}
trap 'on_error $LINENO' ERR
trap cleanup_on_exit EXIT

# Строки, которые остаются на экране в рамке во время установки
build_screen_lines() {
  local extras=()
  [[ "$INSTALL_PMA" == "yes" ]] && extras+=("phpMyAdmin")
  [[ "$INSTALL_SSL" == "yes" ]] && extras+=("SSL")
  [[ "$INSTALL_FIREWALL" == "yes" ]] && extras+=("UFW+fail2ban")
  local extras_str="нет"
  [[ ${#extras[@]} -gt 0 ]] && extras_str="$(IFS=', '; echo "${extras[*]}")"

  printf 'Сайт            %s\n' "$SITE_DOMAIN"
  printf 'Название        %s\n' "$SITE_TITLE"
  printf 'Каталог         %s\n' "$WP_PATH"
  printf 'Окружение       %s · PHP %s · %s\n' "$WEB_SERVER" "$PHP_VERSION" "$DB_ENGINE"
  printf 'База данных     %s / %s (префикс %s)\n' "$DB_NAME" "$DB_USER" "$TABLE_PREFIX"
  printf 'Администратор   %s <%s>\n' "$WP_ADMIN_USER" "$WP_EMAIL"
  printf 'Язык            %s\n' "$WP_LOCALE"
  printf 'PHP             upload %s · vars %s · memory %s · exec %s c\n' \
    "$UPLOAD_MAX" "$MAX_INPUT_VARS" "$PHP_MEMORY_LIMIT" "$MAX_EXEC_TIME"
  printf 'Компоненты      %s\n' "$extras_str"
  printf 'Журнал          %s\n' "$LOG_FILE"
}

# Число этапов = число вызовов info() в ходе установки
count_phases() {
  local n=11
  [[ "$INSTALL_PMA" == "yes" ]] && n=$(( n + 1 ))
  [[ "$INSTALL_SSL" == "yes" ]] && n=$(( n + 1 ))
  [[ "$INSTALL_FIREWALL" == "yes" ]] && n=$(( n + 1 ))
  printf '%s' "$n"
}

main() {
  parse_args "$@"
  require_root
  init_log
  log "wp-autoinstall v${VERSION}"

  printf '\n%s wp-autoinstall v%s %s\n' "$C_BOLD" "$VERSION" "$C_RESET"
  check_os
  load_config
  ui_init

  collect_params
  confirm_params

  # С этого места экран не прокручивается: параметры остаются в рамке сверху,
  # снизу обновляются прогресс-бар и строка пояснений.
  local -a screen_lines=()
  mapfile -t screen_lines < <(build_screen_lines)
  screen_start "$(count_phases)" "${screen_lines[@]}" || true

  install_base_packages
  detect_php
  configure_php
  setup_database

  install_wp_cli
  download_wordpress
  configure_wordpress

  setup_phpmyadmin
  configure_webserver
  install_wordpress_core

  setup_ssl
  setup_firewall
  harden_permissions

  screen_finish
  save_credentials
  print_summary
}

main "$@"
