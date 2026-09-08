#!/usr/bin/env bash
# lib/tuning.sh — настройка PHP-FPM, СУБД и системы под реальную нагрузку.
#
# Мотив: сайт может «лежать» при живом сервере. Пул PHP-FPM по умолчанию — пять
# воркеров; несколько медленных запросов (например, штатный поиск WordPress по
# большой базе) занимают их все, nginx ждёт бэкенд, снаружи это выглядит как
# падение сайта. Лечится тремя вещами: воркеров больше, запрос не может висеть
# вечно, тяжёлый SQL убивается по таймауту.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях

RAM_MB=0
CPU_CORES=1

detect_resources() {
  RAM_MB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)"
  [[ "$RAM_MB" =~ ^[0-9]+$ ]] && (( RAM_MB > 0 )) || RAM_MB=1024
  CPU_CORES="$(nproc 2>/dev/null || echo 1)"
  log "[INFO] ресурсы: RAM ${RAM_MB} МБ, ядер ${CPU_CORES}, ядро $(uname -r)"
}

# ------------------------------------------------------------------- PHP-FPM
# Сколько воркеров поднимать. Из памяти вычитаем то, что заберут система и
# кэш СУБД, остаток делим на средний размер воркера WordPress.
calc_max_children() {
  local reserve_sys=512 reserve_db per_worker=128 n
  reserve_db=$(( RAM_MB / 4 ))                  # столько уйдёт в innodb_buffer_pool
  n=$(( (RAM_MB - reserve_sys - reserve_db) / per_worker ))
  (( n < 5 ))  && n=5
  (( n > 30 )) && n=30
  printf '%s' "$n"
}

tune_php_fpm() {
  info "Настройка пула PHP-FPM"
  local pool="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
  if [[ ! -f "$pool" ]]; then
    warn "Не найден ${pool} — пул не настроен."
    return 0
  fi

  local children start_srv min_spare max_spare timeout slowlog
  children="${FPM_MAX_CHILDREN:-$(calc_max_children)}"
  timeout="${FPM_TIMEOUT:-$(( ${MAX_EXEC_TIME:-300} + 30 ))}"
  slowlog="/var/log/php${PHP_VER}-fpm-slow.log"

  # dynamic-пул требует min_spare <= start <= max_spare <= max_children
  start_srv=$(( children / 4 )); (( start_srv < 2 )) && start_srv=2
  min_spare=$(( children / 8 )); (( min_spare < 1 )) && min_spare=1
  max_spare=$(( children / 2 )); (( max_spare < start_srv )) && max_spare="$start_srv"
  (( max_spare > children )) && max_spare="$children"

  cp -a "$pool" "${pool}.wp-autoinstall.bak" 2>/dev/null || true

  # sed по закомментированным строкам тоже — параметры в www.conf часто с ';'
  sed -i -E \
    -e "s|^;?[[:space:]]*pm[[:space:]]*=.*|pm = dynamic|" \
    -e "s|^;?[[:space:]]*pm\.max_children[[:space:]]*=.*|pm.max_children = ${children}|" \
    -e "s|^;?[[:space:]]*pm\.start_servers[[:space:]]*=.*|pm.start_servers = ${start_srv}|" \
    -e "s|^;?[[:space:]]*pm\.min_spare_servers[[:space:]]*=.*|pm.min_spare_servers = ${min_spare}|" \
    -e "s|^;?[[:space:]]*pm\.max_spare_servers[[:space:]]*=.*|pm.max_spare_servers = ${max_spare}|" \
    -e "s|^;?[[:space:]]*pm\.max_requests[[:space:]]*=.*|pm.max_requests = 500|" \
    -e "s|^;?[[:space:]]*request_terminate_timeout[[:space:]]*=.*|request_terminate_timeout = ${timeout}s|" \
    -e "s|^;?[[:space:]]*request_slowlog_timeout[[:space:]]*=.*|request_slowlog_timeout = 5s|" \
    -e "s|^;?[[:space:]]*slowlog[[:space:]]*=.*|slowlog = ${slowlog}|" \
    "$pool"

  # чего в файле не было — дописываем
  local k
  for k in "pm = dynamic" \
           "pm.max_children = ${children}" \
           "pm.start_servers = ${start_srv}" \
           "pm.min_spare_servers = ${min_spare}" \
           "pm.max_spare_servers = ${max_spare}" \
           "pm.max_requests = 500" \
           "request_terminate_timeout = ${timeout}s" \
           "request_slowlog_timeout = 5s" \
           "slowlog = ${slowlog}"; do
    grep -qxF "$k" "$pool" || printf '%s\n' "$k" >> "$pool"
  done

  touch "$slowlog"
  chown www-data:www-data "$slowlog" 2>/dev/null || true
  chmod 640 "$slowlog"

  # бинарник называется php-fpm8.3 / php-fpm; на некоторых сборках его нет вовсе
  local fpm_bin=""
  if require_cmd "php-fpm${PHP_VER}"; then fpm_bin="php-fpm${PHP_VER}"
  elif require_cmd php-fpm;            then fpm_bin="php-fpm"
  fi

  local conf_ok=0
  if [[ -n "$fpm_bin" ]]; then
    run "$fpm_bin" -t && conf_ok=1
  else
    warn "Не нашёл php-fpm для проверки конфигурации — полагаюсь на службу."
    conf_ok=1
  fi

  if (( conf_ok == 1 )); then
    svc_restart "$PHP_FPM_SERVICE"
    ok "Пул: ${children} воркеров, запрос обрывается через ${timeout} с, медленные пишутся в ${slowlog}"
  else
    warn "Конфигурация пула не прошла проверку — возвращаю прежнюю."
    mv "${pool}.wp-autoinstall.bak" "$pool" 2>/dev/null || true
    run systemctl restart "$PHP_FPM_SERVICE" || true
  fi
}

# ----------------------------------------------------------------------- СУБД
db_is_mariadb() {
  "$DB_CLIENT" "${DB_AUTH_ARGS[@]}" -N -B -e 'SELECT VERSION()' 2>/dev/null | grep -qi mariadb
}

db_conf_dir() {
  local d
  for d in /etc/mysql/mariadb.conf.d /etc/mysql/mysql.conf.d /etc/mysql/conf.d /etc/my.cnf.d; do
    [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

tune_database() {
  info "Настройка СУБД"
  local dir
  if ! dir="$(db_conf_dir)"; then
    warn "Не найден каталог конфигурации СУБД — настройка пропущена."
    return 0
  fi

  local pool_mb limit
  pool_mb="${DB_BUFFER_POOL_MB:-$(( RAM_MB / 4 ))}"
  (( pool_mb < 128 )) && pool_mb=128
  limit="${DB_MAX_STATEMENT_TIME:-30}"

  local conf="${dir}/99-wp-autoinstall.cnf"
  {
    printf '# Создано wp-autoinstall\n'
    printf '[mysqld]\n'
    printf 'innodb_buffer_pool_size = %sM\n' "$pool_mb"
    if db_is_mariadb; then
      # MariaDB: секунды
      printf 'max_statement_time = %s\n' "$limit"
    else
      # MySQL: миллисекунды и другое имя переменной
      printf 'max_execution_time = %s\n' "$(( limit * 1000 ))"
    fi
    printf 'slow_query_log = 1\n'
    printf 'slow_query_log_file = /var/log/mysql/slow.log\n'
    printf 'long_query_time = 3\n'
  } > "$conf"
  chmod 644 "$conf"

  mkdir -p /var/log/mysql
  chown mysql:mysql /var/log/mysql 2>/dev/null || true

  if run systemctl restart "$DB_SERVICE"; then
    local i
    for i in $(seq 1 30); do
      "$DB_CLIENT" "${DB_AUTH_ARGS[@]}" -e 'SELECT 1' >/dev/null 2>&1 && break
      sleep 1
    done
    ok "СУБД: буфер ${pool_mb} МБ, тяжёлый запрос обрывается через ${limit} с, медленные пишутся в /var/log/mysql/slow.log"
  else
    warn "СУБД не перезапустилась с новой конфигурацией — убираю её."
    rm -f "$conf"
    run systemctl restart "$DB_SERVICE" || true
  fi
}

# -------------------------------------------------------------- файл подкачки
setup_swap() {
  [[ "${SETUP_SWAP}" == "yes" ]] || return 0
  info "Файл подкачки"

  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    ok "Подкачка уже настроена — пропускаем"
    return 0
  fi

  local size="${SWAP_SIZE:-2G}" num unit need_mb avail_mb
  num="${size%[MG]}"; unit="${size: -1}"
  need_mb="$num"; [[ "$unit" == "G" ]] && need_mb=$(( num * 1024 ))
  avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  if (( avail_mb < need_mb * 2 )); then
    warn "На диске ${avail_mb} МБ — мало для файла подкачки ${size}, пропускаем."
    return 0
  fi

  step "Создание /swapfile на ${size}"
  if ! run fallocate -l "$size" /swapfile; then
    rm -f /swapfile
    run dd if=/dev/zero of=/swapfile bs=1M count="$need_mb" || {
      warn "Не удалось создать файл подкачки."; rm -f /swapfile; return 0; }
  fi
  chmod 600 /swapfile
  run mkswap /swapfile || { warn "mkswap не отработал."; rm -f /swapfile; return 0; }
  if ! run swapon /swapfile; then
    warn "Ядро не приняло файл подкачки (бывает в контейнерах) — пропускаем."
    rm -f /swapfile
    return 0
  fi
  grep -qs '^/swapfile' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-wp-autoinstall.conf
  run sysctl -p /etc/sysctl.d/99-wp-autoinstall.conf || true
  ok "Подкачка ${size} включена и прописана в /etc/fstab"
}

# --------------------------------------------------------------- robots.txt
write_robots() {
  [[ "${CREATE_ROBOTS}" == "yes" ]] || return 0
  local f="${WP_PATH}/robots.txt"
  if [[ -f "$f" ]]; then
    step "robots.txt уже есть — не трогаем"
    return 0
  fi
  cat > "$f" <<ROBOTS
User-agent: *
Disallow: /search/
Disallow: /*?s=
Disallow: /*?p=
Disallow: /wp-admin/
Allow: /wp-admin/admin-ajax.php

Sitemap: ${WP_URL_SCHEME}://${SITE_DOMAIN}/wp-sitemap.xml
ROBOTS
  chown www-data:www-data "$f"
  chmod 644 "$f"
  ok "robots.txt создан: поиск закрыт от индексации"
}

# ------------------------------------------------------- проверка после установки
install_healthcheck() {
  local bin="/usr/local/bin/wp-autoinstall-check"
  cat > "$bin" <<'CHECK'
#!/usr/bin/env bash
# Проверка состояния сайта, установленного wp-autoinstall.
# Использование: wp-autoinstall-check ДОМЕН
set -uo pipefail
D="${1:-}"
[[ -n "$D" ]] || { echo "Использование: $0 ДОМЕН"; exit 2; }

echo "=== Ответ сайта ==="
curl -sk -o /dev/null -m 15 -w 'код %{http_code}, время %{time_total} с\n' "https://${D}/" \
  || curl -s -o /dev/null -m 15 -w 'код %{http_code}, время %{time_total} с (http)\n' "http://${D}/"

echo
echo "=== PHP-FPM ==="
for p in /etc/php/*/fpm/pool.d/www.conf; do
  [[ -f "$p" ]] || continue
  echo "$p"
  grep -E '^(pm\.max_children|request_terminate_timeout|request_slowlog_timeout)' "$p" | sed 's/^/  /'
done
for l in /var/log/php*-fpm.log; do
  [[ -f "$l" ]] || continue
  n=$(grep -c 'max_children' "$l" 2>/dev/null) || n=0
  echo "  упоминаний max_children в $l (нехватка воркеров): ${n:-0}"
done

echo
echo "=== СУБД ==="
if command -v mysql >/dev/null 2>&1; then
  mysql -Ne "SELECT CONCAT('  buffer_pool = ', ROUND(@@innodb_buffer_pool_size/1024/1024), ' МБ')" 2>/dev/null
  mysql -Ne "SELECT CONCAT('  max_statement_time = ', @@max_statement_time)" 2>/dev/null \
    || mysql -Ne "SELECT CONCAT('  max_execution_time = ', @@max_execution_time, ' мс')" 2>/dev/null
  echo "  запросы дольше 10 с прямо сейчас:"
  mysql -Ne "SELECT CONCAT('    ', id, ' | ', time, ' с | ', LEFT(REPLACE(info,'\n',' '),70))
             FROM information_schema.processlist WHERE time > 10 AND command != 'Sleep'" 2>/dev/null \
    || echo "    (нет доступа к processlist)"
fi

echo
echo "=== Порты наружу (должны быть только ssh и веб) ==="
ss -tlnH 2>/dev/null | awk '{print $4}' | grep -v '^127\.0\.0\.1' | grep -v '^\[::1\]' | sort -u | sed 's/^/  /'

echo
echo "=== Медленные ответы за последние сутки (дольше 5 с) ==="
for a in /var/log/nginx/${D}.access.log /var/log/nginx/access.log; do
  [[ -f "$a" ]] || continue
  awk '{ for (i=NF; i>0; i--) if ($i ~ /^[0-9]+\.[0-9]+$/) { if ($i+0 > 5) print; break } }' "$a" | tail -n 5
done

echo
echo "=== Подкачка ==="
swapon --show 2>/dev/null | sed 's/^/  /' || echo "  не настроена"
CHECK
  chmod 755 "$bin"
  ok "Установлена команда проверки: wp-autoinstall-check ${SITE_DOMAIN}"
}

run_healthcheck() {
  info "Проверка после установки"
  install_healthcheck
  printf '\n'
  /usr/local/bin/wp-autoinstall-check "$SITE_DOMAIN" 2>&1 | tee -a "$LOG_FILE" | sed 's/^/  /'
  printf '\n'
}
