#!/usr/bin/env bash
# lib/database.sh — подготовка MySQL/MariaDB: подключение под root, создание БД и пользователя.
# shellcheck shell=bash

DB_AUTH_ARGS=()
DB_CLIENT=""

start_db_service() {
  DB_SERVICE="${DB_SERVICE:-}"
  if [[ -z "$DB_SERVICE" ]]; then
    if service_exists mariadb; then DB_SERVICE=mariadb
    elif service_exists mysql; then DB_SERVICE=mysql
    else die "Не найдена служба mysql/mariadb."; fi
  fi
  run systemctl enable "$DB_SERVICE" || true
  systemctl is-active --quiet "$DB_SERVICE" || run systemctl start "$DB_SERVICE" \
    || die "Не удалось запустить $DB_SERVICE. Проверьте: systemctl status $DB_SERVICE"
  # ждём готовности сокета (до 30 секунд)
  local i
  for i in $(seq 1 30); do
    "$DB_CLIENT" --protocol=socket -u root -e 'SELECT 1' >/dev/null 2>&1 && break
    "$DB_CLIENT" -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done
  ok "СУБД запущена ($DB_SERVICE)"
}

pick_db_client() {
  if require_cmd mysql; then DB_CLIENT=mysql
  elif require_cmd mariadb; then DB_CLIENT=mariadb
  else die "Не найден клиент mysql/mariadb."; fi
}

db_exec() { "$DB_CLIENT" "${DB_AUTH_ARGS[@]}" -N -B -e "$1"; }

db_try() { "$DB_CLIENT" "$@" -N -B -e 'SELECT 1' >/dev/null 2>&1; }

# Пароль root не передаём через -pПАРОЛЬ: его видно в `ps` любому пользователю
# машины. Кладём во временный файл 600 и подключаемся --defaults-extra-file.
DB_ROOT_CNF=""
db_root_cnf() { # db_root_cnf ПАРОЛЬ — пишет файл и оставляет путь в DB_ROOT_CNF
  local p
  p="$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"   # \ и " экранируем для my.cnf
  [[ -n "$DB_ROOT_CNF" ]] || DB_ROOT_CNF="$(mktemp /root/.wp-autoinstall-db.XXXXXX)"
  chmod 600 "$DB_ROOT_CNF"
  printf '[client]\nuser=root\npassword="%s"\n' "$p" > "$DB_ROOT_CNF"
}

try_root_pass() { # try_root_pass ПАРОЛЬ -> 0, если подошёл (и DB_AUTH_ARGS готовы)
  db_root_cnf "$1"
  if db_try --defaults-extra-file="$DB_ROOT_CNF"; then
    DB_ROOT_PASS="$1"; DB_AUTH_ARGS=(--defaults-extra-file="$DB_ROOT_CNF"); return 0
  fi
  return 1
}

# Временный пароль, который mysqld --initialize пишет в журнал ошибок
# (так ставят MySQL из репозитория Oracle и из архивов). Он сразу «истёкший»:
# с ним разрешена только смена пароля, поэтому меняем его здесь же.
mysql_temp_password() {
  local f
  for f in /var/log/mysqld.log /var/log/mysql/error.log /var/log/mysql/mysqld.log; do
    [[ -r "$f" ]] || continue
    sed -n 's/.*temporary password is generated for root@localhost: //p' "$f" | tail -n1
    return 0
  done
}

use_expired_temp_password() {
  local tmp new
  tmp="$(mysql_temp_password)"
  [[ -n "$tmp" ]] || return 1
  new="$(rand_pass 24)"
  db_root_cnf "$tmp"
  "$DB_CLIENT" --defaults-extra-file="$DB_ROOT_CNF" --connect-expired-password -N -B \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${new}';" >>"$LOG_FILE" 2>&1 || return 1
  try_root_pass "$new" || return 1
  save_root_my_cnf "$new"
  ok "Временный пароль root из журнала MySQL заменён на новый (сохранён в /root/.my.cnf)"
}

save_root_my_cnf() { # чтобы root сервера и дальше входил в СУБД командой `mysql`
  local f=/root/.my.cnf
  [[ -f "$f" ]] && cp -p "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
  printf '[client]\nuser=root\npassword="%s"\n' "$1" > "$f"
  chmod 600 "$f"
}

# Сброс забытого пароля root. Проверено на MySQL 8.4 (в том числе 8.4.11),
# работает и на 8.0 и на MariaDB. Ловушки 8.4, из-за которых «рецепты из
# интернета» не срабатывают:
#   * mysql_native_password в 8.4 по умолчанию выключен — ALTER USER ...
#     IDENTIFIED WITH mysql_native_password падает с «Plugin is not loaded»,
#     ставим caching_sha2_password (его понимает PHP 7.4+);
#   * под --skip-grant-tables ALTER USER отказывает, пока не сделать
#     FLUSH PRIVILEGES — он загружает таблицы прав обратно;
#   * systemctl set-environment MYSQLD_OPTS работает только с юнитом Oracle,
#     у пакета Ubuntu ExecStart эту переменную не читает — поэтому mysqld
#     запускаем руками, без сети (--skip-networking), и гасим mysqladmin'ом.
reset_db_root_password() {
  local new mysqld pid i sock_dir=/run/mysqld
  new="$(rand_pass 24)"
  mysqld="$(command -v mysqld || command -v mariadbd || true)"
  [[ -n "$mysqld" ]] || { err "Не найден mysqld — сбросить пароль нечем."; return 1; }

  step "Остановка ${DB_SERVICE} для сброса пароля root"
  run systemctl stop "$DB_SERVICE" || true
  mkdir -p "$sock_dir"; chown mysql:mysql "$sock_dir" 2>/dev/null || true

  step "Запуск без проверки прав (только локальный сокет)"
  "$mysqld" --user=mysql --skip-grant-tables --skip-networking \
    --pid-file="${sock_dir}/wp-reset.pid" >>"$LOG_FILE" 2>&1 &
  pid=$!
  for i in $(seq 1 30); do
    "$DB_CLIENT" -u root -N -B -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done

  local ok_reset=0
  if "$DB_CLIENT" -u root -N -B -e "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${new}';" >>"$LOG_FILE" 2>&1; then
    ok_reset=1
  elif "$DB_CLIENT" -u root -N -B -e "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED BY '${new}';" >>"$LOG_FILE" 2>&1; then
    ok_reset=1   # MariaDB: плагина caching_sha2_password там нет
  fi

  mysqladmin -u root shutdown >>"$LOG_FILE" 2>&1 || kill "$pid" 2>/dev/null || true
  for i in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  run systemctl start "$DB_SERVICE" || die "Не удалось снова запустить ${DB_SERVICE} после сброса пароля."
  for i in $(seq 1 30); do
    "$DB_CLIENT" --protocol=socket -u root -e 'SELECT 1' >/dev/null 2>&1 && break
    try_root_pass "$new" && break
    sleep 1
  done

  (( ok_reset == 1 )) || { err "Сменить пароль root не удалось (подробности в журнале)."; return 1; }
  try_root_pass "$new" || return 1
  save_root_my_cnf "$new"
  ok "Пароль root СУБД сброшен и сохранён в /root/.my.cnf"
}

detect_db_root_auth() {
  info "Подключение к СУБД"

  if [[ -n "${DB_ROOT_PASS:-}" ]]; then
    try_root_pass "$DB_ROOT_PASS" && { ok "Вход под root по паролю"; return 0; }
    warn "Указанный пароль root к СУБД не подошёл — пробуем другие способы."
  fi

  if db_try -u root; then
    DB_AUTH_ARGS=(-u root); ok "Вход под root через сокет"; return 0
  fi

  if [[ -r /root/.my.cnf ]] && db_try --defaults-extra-file=/root/.my.cnf; then
    DB_AUTH_ARGS=(--defaults-extra-file=/root/.my.cnf)
    ok "Вход под root по /root/.my.cnf"; return 0
  fi

  if [[ -r /etc/mysql/debian.cnf ]] && db_try --defaults-file=/etc/mysql/debian.cnf; then
    DB_AUTH_ARGS=(--defaults-file=/etc/mysql/debian.cnf)
    ok "Вход через служебную учётную запись Debian/Ubuntu"; return 0
  fi

  use_expired_temp_password && return 0

  # Пароль root неизвестен. На свежей СУБД (поставили только что) сбрасываем
  # без вопросов, на чужой — только с согласия.
  warn "Пароль root к ${DB_SERVICE} неизвестен."
  local do_reset=no
  case "${DB_ROOT_RESET:-ask}" in
    yes) do_reset=yes ;;
    no)  do_reset=no ;;
    *)
      if [[ "${DB_INSTALLED_BEFORE:-1}" == "0" ]]; then do_reset=yes
      elif [[ "$ASSUME_YES" != "1" ]] && confirm "Сбросить пароль root (СУБД будет перезапущена, базы не пострадают)?" "no"; then do_reset=yes
      fi ;;
  esac
  if [[ "$do_reset" == "yes" ]]; then
    reset_db_root_password && return 0
  fi

  if [[ "$ASSUME_YES" == "1" ]]; then
    die "Нет доступа к СУБД под root. Передайте пароль (--db-root-pass) или разрешите сброс (--db-root-reset)."
  fi

  local pass i
  for i in 1 2 3; do
    read -r -s -p "$(printf '%s?%s Пароль root для %s: ' "$C_BLUE" "$C_RESET" "$DB_SERVICE")" pass || true
    printf '\n'
    try_root_pass "$pass" && { ok "Вход под root по паролю"; return 0; }
    err "Неверный пароль (попытка $i из 3)"
  done
  die "Не удалось подключиться к СУБД под root. Ручной сброс: docs/mysql-root-reset.md"
}

setup_database() {
  pick_db_client
  start_db_service
  detect_db_root_auth

  info "Создание базы данных"
  local exists
  exists="$(db_exec "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';" || true)"
  if [[ -n "$exists" ]]; then
    warn "База данных '${DB_NAME}' уже существует."
    if [[ "${FORCE:-0}" == "1" ]] || confirm "Удалить её вместе со всем содержимым и создать заново?" "no"; then
      local dump
      dump="/root/backup-${DB_NAME}-$(date +%Y%m%d%H%M%S).sql"
      step "Резервная копия базы -> ${dump}"
      if "$DB_CLIENT" "${DB_AUTH_ARGS[@]}" --version >/dev/null 2>&1 && require_cmd mysqldump; then
        mysqldump "${DB_AUTH_ARGS[@]}" "$DB_NAME" > "$dump" 2>>"$LOG_FILE" && chmod 600 "$dump" \
          && ok "Копия сохранена: $dump" || warn "Не удалось сделать дамп — продолжаем."
      fi
      db_exec "DROP DATABASE \`${DB_NAME}\`;"
      ok "База '${DB_NAME}' удалена"
    else
      die "Установка остановлена: выберите другое имя базы данных (--db-name)."
    fi
  fi

  db_exec "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  ok "База '${DB_NAME}' создана (utf8mb4)"

  step "Создание пользователя '${DB_USER}'"
  db_exec "DROP USER IF EXISTS '${DB_USER}'@'localhost';"
  db_exec "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  db_exec "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
  db_exec "FLUSH PRIVILEGES;"

  if MYSQL_PWD="$DB_PASS" db_try -u "$DB_USER"; then
    ok "Пользователь '${DB_USER}' создан, доступ проверен"
  else
    die "Пользователь создан, но подключиться под ним не удалось."
  fi
}
