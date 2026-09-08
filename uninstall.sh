#!/usr/bin/env bash
# shellcheck disable=SC2034  # переменные используются в подключаемых модулях
#
# wp-autoinstall — удаление сайта, созданного install.sh.
# Удаляет каталог сайта, конфигурацию веб-сервера, базу данных и её пользователя.
# Системные пакеты (Nginx/PHP/MariaDB) не трогаются.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/wp-autoinstall-uninstall.log"
ASSUME_YES=0
VERBOSE=0
FORCE=0
UI_MODE=text
SITE_DOMAIN=""; DB_NAME=""; DB_USER=""; DB_ROOT_PASS=""; DB_SERVICE=""; WP_PATH=""; KEEP_DB=no

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib/database.sh"

usage() {
  cat <<'U'
Удаление сайта WordPress, установленного wp-autoinstall.

  sudo ./uninstall.sh --domain example.com [--db-name wp_x] [--db-user wpuser_x]
                      [--keep-db] [--yes]

  --domain ДОМЕН     Домен сайта (обязательно)
  --path ПУТЬ        Каталог сайта (по умолчанию /var/www/ДОМЕН)
  --db-name ИМЯ      Имя базы данных для удаления
  --db-user ИМЯ      Пользователь базы данных для удаления
  --db-root-pass П   Пароль root для СУБД
  --keep-db          Не трогать базу данных
  -y, --yes          Не задавать вопросов
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --domain) SITE_DOMAIN="${2:?}"; shift 2 ;;
    --path) WP_PATH="${2:?}"; shift 2 ;;
    --db-name) DB_NAME="${2:?}"; shift 2 ;;
    --db-user) DB_USER="${2:?}"; shift 2 ;;
    --db-root-pass) DB_ROOT_PASS="${2:?}"; shift 2 ;;
    --keep-db) KEEP_DB=yes; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    *) echo "Неизвестная опция: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_root
init_log
[[ -n "$SITE_DOMAIN" ]] || { usage >&2; die "Укажите --domain"; }
WP_PATH="${WP_PATH:-/var/www/${SITE_DOMAIN}}"

info "Будет удалено"
printf '  Каталог сайта ......... %s\n' "$WP_PATH"
printf '  Конфигурация Nginx .... /etc/nginx/sites-*/%s.conf\n' "$SITE_DOMAIN"
printf '  Конфигурация Apache ... /etc/apache2/sites-*/%s.conf\n' "$SITE_DOMAIN"
[[ "$KEEP_DB" == "no" && -n "$DB_NAME" ]] && printf '  База данных ........... %s\n' "$DB_NAME"
[[ "$KEEP_DB" == "no" && -n "$DB_USER" ]] && printf '  Пользователь БД ....... %s\n' "$DB_USER"
printf '\n'
if [[ "$ASSUME_YES" != "1" ]]; then
  confirm "Продолжить удаление?" "no" || die "Отменено."
fi

if [[ -d "$WP_PATH" ]]; then
  BAK="/root/backup-site-${SITE_DOMAIN}-$(date +%Y%m%d%H%M%S).tar.gz"
  step "Архив сайта -> ${BAK}"
  tar -czf "$BAK" -C "$(dirname "$WP_PATH")" "$(basename "$WP_PATH")" 2>>"$LOG_FILE" && chmod 600 "$BAK" \
    && ok "Копия сохранена: $BAK" || warn "Не удалось создать архив."
  rm -rf "$WP_PATH"
  ok "Каталог удалён"
fi

rm -f "/etc/nginx/sites-enabled/${SITE_DOMAIN}.conf" "/etc/nginx/sites-available/${SITE_DOMAIN}.conf"
if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then systemctl reload nginx || true; fi
if command -v a2dissite >/dev/null 2>&1; then a2dissite "${SITE_DOMAIN}.conf" >/dev/null 2>&1 || true; fi
rm -f "/etc/apache2/sites-available/${SITE_DOMAIN}.conf"
if command -v apache2ctl >/dev/null 2>&1 && apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2 || true; fi
rm -f "/etc/fail2ban/jail.d/wp-autoinstall.local"
for d in "/etc/nginx/wp-autoinstall/${SITE_DOMAIN}.d" "/etc/apache2/wp-autoinstall/${SITE_DOMAIN}.d"; do
  if [[ -d "$d" ]]; then
    BAKD="/root/backup-rules-${SITE_DOMAIN}-$(date +%Y%m%d%H%M%S)"
    mkdir -p "$BAKD" && cp -a "$d"/. "$BAKD"/ 2>/dev/null || true
    rm -rf "$d"
    ok "Свои правила сервера сохранены в ${BAKD} и удалены"
  fi
done
ok "Конфигурация веб-сервера удалена"

if [[ "$KEEP_DB" == "no" && ( -n "$DB_NAME" || -n "$DB_USER" ) ]]; then
  pick_db_client
  start_db_service
  detect_db_root_auth
  if [[ -n "$DB_NAME" ]]; then
    DUMP="/root/backup-${DB_NAME}-$(date +%Y%m%d%H%M%S).sql"
    if command -v mysqldump >/dev/null 2>&1; then
      mysqldump "${DB_AUTH_ARGS[@]}" "$DB_NAME" > "$DUMP" 2>>"$LOG_FILE" && chmod 600 "$DUMP" \
        && ok "Дамп базы: $DUMP" || warn "Дамп не создан."
    fi
    db_exec "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" && ok "База ${DB_NAME} удалена"
  fi
  if [[ -n "$DB_USER" ]]; then
    db_exec "DROP USER IF EXISTS '${DB_USER}'@'localhost';" && ok "Пользователь ${DB_USER} удалён"
  fi
fi

printf '\n'
ok "Готово. Резервные копии лежат в /root/"
