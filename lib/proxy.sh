#!/usr/bin/env bash
# lib/proxy.sh — выход в интернет через прокси на «чистом» сервере.
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях
#
# Где прокси нужен и почему его мало просто экспортировать:
#   * `sudo ./install.sh` сбрасывает окружение (env_reset) — переменные,
#     заданные в сессии пользователя, до скрипта не доходят;
#   * apt берёт прокси не из окружения, а из Acquire::http::Proxy;
#   * WP-CLI запускается через `sudo -u www-data`, и sudo снова всё стирает;
#   * curl читает только строчное http_proxy (заглавное игнорирует нарочно);
#   * сам WordPress переменных окружения не видит вовсе — ему нужны
#     константы WP_PROXY_* в wp-config.php, иначе не работают обновления,
#     установка плагинов и языковых пакетов из админки.

PROXY_URL="${PROXY_URL:-}"
NO_PROXY_LIST="${NO_PROXY_LIST:-}"
PROXY_HOST=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""

# Откуда взять прокси, если его не передали явно: окружение, /etc/environment
# (sudo читает его через pam_env не всегда), настройки apt.
proxy_autodetect() {
  local p=""
  p="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
  if [[ -z "$p" && -r /etc/environment ]]; then
    p="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?(https?_proxy|HTTPS?_PROXY)=["'\'']?([^"'\'' ]+).*/\3/p' /etc/environment | head -n1)"
  fi
  if [[ -z "$p" ]] && require_cmd apt-config; then
    p="$(apt-config dump 2>/dev/null | sed -nE 's/^Acquire::https?::Proxy "([^"]+)";/\1/p' | grep -v '^DIRECT$' | head -n1)"
  fi
  printf '%s' "$p"
}

v_proxy() {
  local x="$1"
  [[ -z "$x" ]] && return 0
  [[ "$x" =~ ^https?://([^/@]+@)?[A-Za-z0-9._-]+:[0-9]{1,5}/?$ ]] && return 0
  echo "формат: http://хост:порт или http://логин:пароль@хост:порт"; return 1
}

# http://user:pass@host:port/ -> PROXY_HOST, PROXY_PORT, PROXY_USER, PROXY_PASS
proxy_parse() {
  local rest="${PROXY_URL#*://}" auth=""
  rest="${rest%/}"
  if [[ "$rest" == *@* ]]; then auth="${rest%@*}"; rest="${rest##*@}"; fi
  PROXY_HOST="${rest%:*}"
  PROXY_PORT="${rest##*:}"
  PROXY_USER="${auth%%:*}"
  PROXY_PASS=""; [[ "$auth" == *:* ]] && PROXY_PASS="${auth#*:}"
  # В URL спецсимволы пароля кодируются (%40 = @). curl раскодирует сам,
  # а WordPress берёт константу как есть — ему отдаём раскодированное.
  PROXY_USER="$(printf '%b' "${PROXY_USER//%/\\x}")"
  PROXY_PASS="$(printf '%b' "${PROXY_PASS//%/\\x}")"
  return 0
}

setup_proxy() {
  [[ -n "$PROXY_URL" ]] || PROXY_URL="$(proxy_autodetect)"
  [[ "$PROXY_URL" == "none" ]] && PROXY_URL=""
  if [[ -z "$PROXY_URL" ]]; then
    log "[INFO] прокси не задан, выход в интернет напрямую"
    return 0
  fi
  local msg
  msg="$(v_proxy "$PROXY_URL")" || die "Неверный адрес прокси '${PROXY_URL}': ${msg}"
  proxy_parse

  # Локальные адреса — мимо прокси, иначе WordPress стучится сам к себе
  # (wp-cron, проверка REST) через прокси и получает отказ.
  local np="localhost,127.0.0.1,::1"
  [[ -n "${SITE_DOMAIN:-}" ]] && np+=",${SITE_DOMAIN},www.${SITE_DOMAIN}"
  [[ -n "$NO_PROXY_LIST" ]] && np+=",${NO_PROXY_LIST}"
  NO_PROXY_LIST="$np"

  export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
  export no_proxy="$NO_PROXY_LIST" NO_PROXY="$NO_PROXY_LIST"

  # apt: свой файл, только если прокси для apt ещё не настроен кем-то другим
  local aptf="/etc/apt/apt.conf.d/95wp-autoinstall-proxy"
  if apt-config dump 2>/dev/null | grep -q '^Acquire::https\?::Proxy ' && [[ ! -f "$aptf" ]]; then
    log "[INFO] прокси для apt уже настроен в системе — свой файл не пишем"
  else
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY_URL" "$PROXY_URL" > "$aptf"
    chmod 600 "$aptf"
  fi
  ok "Прокси: ${PROXY_HOST}:${PROXY_PORT}${PROXY_USER:+ (с логином)}"
}

# Переменные прокси для `env` под sudo: sudo -u www-data их стирает
proxy_env_args() {
  [[ -n "$PROXY_URL" ]] || return 0
  printf '%s\n' "http_proxy=${PROXY_URL}" "https_proxy=${PROXY_URL}" \
    "HTTP_PROXY=${PROXY_URL}" "HTTPS_PROXY=${PROXY_URL}" \
    "no_proxy=${NO_PROXY_LIST}" "NO_PROXY=${NO_PROXY_LIST}"
}

# Строки для wp-config.php: WordPress ходит наружу через WP_Http, а тот
# смотрит только на эти константы.
proxy_wp_config_lines() {
  [[ -n "$PROXY_URL" ]] || return 0
  echo ""
  echo "/* Прокси для исходящих запросов WordPress (обновления, плагины, языки). */"
  echo "define( 'WP_PROXY_HOST', '$(php_quote "$PROXY_HOST")' );"
  echo "define( 'WP_PROXY_PORT', '$(php_quote "$PROXY_PORT")' );"
  if [[ -n "$PROXY_USER" ]]; then
    echo "define( 'WP_PROXY_USERNAME', '$(php_quote "$PROXY_USER")' );"
    echo "define( 'WP_PROXY_PASSWORD', '$(php_quote "$PROXY_PASS")' );"
  fi
  echo "define( 'WP_PROXY_BYPASS_HOSTS', 'localhost, 127.0.0.1, $(php_quote "${SITE_DOMAIN:-localhost}"), *.$(php_quote "${SITE_DOMAIN:-localhost}")' );"
}

# Проверка выхода в интернет до начала установки: лучше узнать сразу, чем
# через пять минут на загрузке WordPress.
check_internet() {
  require_cmd curl || return 0   # на совсем голой системе curl ещё нет — проверит apt
  step "Проверка выхода в интернет${PROXY_URL:+ через прокси}"
  local url
  for url in https://api.wordpress.org/core/version-check/1.7/ http://archive.ubuntu.com/; do
    if curl -fsS -o /dev/null --max-time 15 "$url" >>"$LOG_FILE" 2>&1; then
      ok "Интернет доступен"; return 0
    fi
  done
  if [[ -z "$PROXY_URL" ]]; then
    warn "Нет выхода в интернет. Если сервер ходит наружу через прокси, задайте его:"
    warn "  --proxy http://хост:порт   (или PROXY_URL= в файле параметров)"
    if [[ "$ASSUME_YES" != "1" && "${CHECK_INTERNET_RETRY:-0}" == "0" ]]; then
      local answer=""
      ask answer "Адрес прокси (Enter — без прокси)" "" v_proxy
      if [[ -n "$answer" ]]; then
        PROXY_URL="$answer"; CHECK_INTERNET_RETRY=1
        setup_proxy
        check_internet
        return
      fi
    fi
  else
    warn "Через прокси ${PROXY_HOST}:${PROXY_PORT} внешние адреса не открываются."
  fi
  if [[ "$ASSUME_YES" != "1" ]] && ! confirm "Продолжить всё равно?" "no"; then
    die "Установка остановлена: нет выхода в интернет."
  fi
}
