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

VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ---- значения по умолчанию (переопределяются конфигом, опциями и вопросами) ----
CONFIG_FILE="${CONFIG_FILE:-}"
ASSUME_YES="${ASSUME_YES:-0}"
VERBOSE="${VERBOSE:-0}"
FORCE="${FORCE:-0}"
UI_MODE="${UI_MODE:-auto}"
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

for f in common.sh ui.sh prompts.sh packages.sh database.sh wordpress.sh webserver.sh extras.sh; do
  [[ -r "${LIB_DIR}/${f}" ]] || { echo "Не найден модуль ${LIB_DIR}/${f}" >&2; exit 1; }
  # shellcheck source=/dev/null
  # shellcheck disable=SC1090,SC1091
  . "${LIB_DIR}/${f}"
done

trap 'on_error $LINENO' ERR
trap 'rm -f /tmp/wp-install-$$.php' EXIT

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

  save_credentials
  print_summary
}

main "$@"
