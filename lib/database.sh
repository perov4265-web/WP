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

detect_db_root_auth() {
  info "Подключение к СУБД"

  if [[ -n "${DB_ROOT_PASS:-}" ]]; then
    if db_try -u root -p"$DB_ROOT_PASS"; then
      DB_AUTH_ARGS=(-u root -p"$DB_ROOT_PASS"); ok "Вход под root по паролю"; return 0
    fi
    warn "Указанный пароль root к СУБД не подошёл — пробуем другие способы."
  fi

  if db_try -u root; then
    DB_AUTH_ARGS=(-u root); ok "Вход под root через сокет"; return 0
  fi

  if [[ -r /etc/mysql/debian.cnf ]] && db_try --defaults-file=/etc/mysql/debian.cnf; then
    DB_AUTH_ARGS=(--defaults-file=/etc/mysql/debian.cnf)
    ok "Вход через служебную учётную запись Debian/Ubuntu"; return 0
  fi

  if [[ "$ASSUME_YES" == "1" ]]; then
    die "Нет доступа к СУБД под root. Передайте пароль: --db-root-pass ПАРОЛЬ"
  fi

  local pass i
  for i in 1 2 3; do
    read -r -s -p "$(printf '%s?%s Пароль root для %s: ' "$C_BLUE" "$C_RESET" "$DB_SERVICE")" pass || true
    printf '\n'
    if db_try -u root -p"$pass"; then
      DB_ROOT_PASS="$pass"; DB_AUTH_ARGS=(-u root -p"$pass"); ok "Вход под root по паролю"; return 0
    fi
    err "Неверный пароль (попытка $i из 3)"
  done
  die "Не удалось подключиться к СУБД под root."
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

  if db_try -u "$DB_USER" -p"$DB_PASS" ; then
    ok "Пользователь '${DB_USER}' создан, доступ проверен"
  else
    die "Пользователь создан, но подключиться под ним не удалось."
  fi
}
