#!/usr/bin/env bash
# lib/common.sh — общие утилиты: вывод, логирование, валидация, ввод параметров.
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях

# ---------- цвета ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''
fi

LOG_FILE="${LOG_FILE:-/var/log/wp-autoinstall.log}"
VERBOSE="${VERBOSE:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# ---------- логирование ----------
init_log() {
  : > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/wp-autoinstall.log"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  log "=== wp-autoinstall $(date '+%F %T') ==="
}
log()  { printf '%s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; }
info() { printf '\n%s>>>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; log "[INFO] $*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log "[ OK ] $*"; }
step() { printf '  %s·%s %s\n' "$C_DIM" "$C_RESET" "$*"; log "[STEP] $*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "[WARN] $*"; }
err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "[ERR ] $*"; }
die()  { err "$*"; printf '\n%sЛог установки: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET" >&2; exit 1; }

on_error() {
  local code=$? line="${1:-?}"
  err "Сбой на строке $line (код возврата $code)."
  printf '\n%sПоследние строки лога (%s):%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET" >&2
  tail -n 15 "$LOG_FILE" >&2 2>/dev/null || true
  exit "$code"
}

# Выполнить команду: тихо в лог, либо с выводом при VERBOSE=1
run() {
  log "[CMD ] $*"
  if [[ "$VERBOSE" == "1" ]]; then
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
  fi
  "$@" >> "$LOG_FILE" 2>&1
}

# ---------- проверки окружения ----------
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Скрипт нужно запускать от root: sudo bash install.sh"
}

require_cmd() { command -v "$1" >/dev/null 2>&1; }

check_os() {
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release — система не поддерживается."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
  OS_VERSION="${VERSION_ID:-неизвестно}"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  if [[ "$OS_ID" != "ubuntu" ]]; then
    if [[ "$OS_LIKE" == *debian* ]]; then
      warn "Обнаружена $OS_ID $OS_VERSION (Debian-совместимая). Скрипт рассчитан на Ubuntu, продолжаем на свой риск."
    else
      die "Поддерживаются только Ubuntu и Debian-совместимые системы (обнаружено: $OS_ID)."
    fi
  fi
  require_cmd apt-get || die "Не найден apt-get."
  ok "Система: ${PRETTY_NAME:-$OS_ID $OS_VERSION}"
}

# ---------- генерация паролей ----------
rand_pass() {
  local len="${1:-20}"
  (
    set +o pipefail
    LC_ALL=C tr -dc 'A-Za-z0-9@#%^_+=' < /dev/urandom | head -c "$len"
  )
  printf '\n'
}

rand_suffix() {
  (
    set +o pipefail
    LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-6}"
  )
  printf '\n'
}

# ---------- валидаторы (0 = ок, иначе текст ошибки в stdout) ----------
v_host() { # домен или IP
  local x="$1"
  [[ -n "$x" ]] || { echo "значение не может быть пустым"; return 1; }
  if [[ "$x" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 0; fi
  if [[ "$x" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then return 0; fi
  echo "укажите корректный домен (example.com) или IPv4-адрес"; return 1
}

v_ident() { # имя БД / пользователя БД
  local x="$1"
  [[ "$x" =~ ^[A-Za-z_][A-Za-z0-9_]{0,31}$ ]] && return 0
  echo "разрешены латиница, цифры и подчёркивание, до 32 символов, не начинаться с цифры"; return 1
}

v_email() {
  local x="$1"
  [[ "$x" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && return 0
  echo "укажите корректный email"; return 1
}

v_notempty() {
  [[ -n "$1" ]] && return 0
  echo "значение не может быть пустым"; return 1
}

v_dbpass() { # пароль БД: без кавычек и обратного слэша — они ломают SQL
  local x="$1"
  [[ ${#x} -ge 8 ]] || { echo "минимум 8 символов"; return 1; }
  [[ "$x" =~ [\'\"\\\`] ]] && { echo "нельзя использовать символы ' \" \` и \\"; return 1; }
  return 0
}

v_wppass() {
  local x="$1"
  [[ ${#x} -ge 8 ]] || { echo "минимум 8 символов"; return 1; }
  return 0
}

v_size() { # 128M / 1G
  local x="$1"
  [[ "$x" =~ ^[0-9]+[MG]$ ]] && return 0
  echo "формат: число + M или G, например 128M"; return 1
}

v_phpver() {
  local x="$1"
  [[ -z "$x" || "$x" == "auto" ]] && return 0
  [[ "$x" =~ ^[0-9]+\.[0-9]+$ ]] && return 0
  echo "формат версии PHP: 8.3 (или auto)"; return 1
}

# ---------- интерактивный ввод ----------
# ask ИМЯ_ПЕРЕМЕННОЙ "Вопрос" "значение по умолчанию" [валидатор]
ask() {
  local __name="$1" prompt="$2" def="${3:-}" validator="${4:-}" input msg
  local current="${!__name-}"
  [[ -n "$current" ]] && def="$current"

  if [[ "$ASSUME_YES" == "1" ]]; then
    [[ -n "$def" ]] || die "Параметр $__name не задан, а режим --yes не позволяет спросить."
    printf -v "$__name" '%s' "$def"
    return 0
  fi

  while true; do
    if [[ -n "$def" ]]; then
      read -r -p "$(printf '%s?%s %s %s[%s]%s: ' "$C_BLUE" "$C_RESET" "$prompt" "$C_DIM" "$def" "$C_RESET")" input || die "Ввод прерван (нет данных на stdin). Используйте --config и --yes."
    else
      read -r -p "$(printf '%s?%s %s: ' "$C_BLUE" "$C_RESET" "$prompt")" input || die "Ввод прерван (нет данных на stdin). Используйте --config и --yes."
    fi
    input="${input:-$def}"
    if [[ -n "$validator" ]] && declare -F "$validator" >/dev/null; then
      if msg="$("$validator" "$input")"; then
        printf -v "$__name" '%s' "$input"; return 0
      else
        err "${msg:-некорректное значение}"; continue
      fi
    fi
    [[ -n "$input" ]] || { err "значение не может быть пустым"; continue; }
    printf -v "$__name" '%s' "$input"; return 0
  done
}

# ask_secret ИМЯ "Вопрос" [валидатор] — скрытый ввод, пустой ввод = сгенерировать
ask_secret() {
  local __name="$1" prompt="$2" validator="${3:-v_dbpass}" a b msg
  local current="${!__name-}"

  if [[ -n "$current" ]]; then
    if msg="$("$validator" "$current")"; then return 0; fi
    die "Значение $__name не проходит проверку: $msg"
  fi
  if [[ "$ASSUME_YES" == "1" ]]; then
    printf -v "$__name" '%s' "$(rand_pass 20)"
    return 0
  fi

  while true; do
    read -r -s -p "$(printf '%s?%s %s %s[Enter — сгенерировать]%s: ' "$C_BLUE" "$C_RESET" "$prompt" "$C_DIM" "$C_RESET")" a || die "Ввод прерван (нет данных на stdin)."
    printf '\n'
    if [[ -z "$a" ]]; then
      a="$(rand_pass 20)"
      printf '  %sСгенерирован пароль:%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$a" "$C_RESET"
      printf -v "$__name" '%s' "$a"; return 0
    fi
    if ! msg="$("$validator" "$a")"; then err "${msg:-некорректный пароль}"; continue; fi
    read -r -s -p "$(printf '%s?%s Повторите пароль: ' "$C_BLUE" "$C_RESET")" b || die "Ввод прерван (нет данных на stdin)."
    printf '\n'
    [[ "$a" == "$b" ]] || { err "пароли не совпадают"; continue; }
    printf -v "$__name" '%s' "$a"; return 0
  done
}

# ask_yn ИМЯ "Вопрос" "yes|no"
ask_yn() {
  local __name="$1" prompt="$2" def="${3:-no}" input
  local current="${!__name-}"
  if [[ -n "$current" ]]; then
    case "${current,,}" in
      1|y|yes|true|да) printf -v "$__name" '%s' "yes"; return 0 ;;
      0|n|no|false|нет) printf -v "$__name" '%s' "no"; return 0 ;;
    esac
  fi
  if [[ "$ASSUME_YES" == "1" ]]; then printf -v "$__name" '%s' "$def"; return 0; fi

  local hint="y/N"; [[ "$def" == "yes" ]] && hint="Y/n"
  while true; do
    read -r -p "$(printf '%s?%s %s %s[%s]%s: ' "$C_BLUE" "$C_RESET" "$prompt" "$C_DIM" "$hint" "$C_RESET")" input || die "Ввод прерван (нет данных на stdin)."
    input="${input:-$def}"
    case "${input,,}" in
      y|yes|да|д) printf -v "$__name" '%s' "yes"; return 0 ;;
      n|no|нет|н) printf -v "$__name" '%s' "no"; return 0 ;;
      *) err "ответьте y (да) или n (нет)" ;;
    esac
  done
}

confirm() { # confirm "Вопрос" "yes|no" -> 0/1
  local answer=""
  local __tmp
  __tmp="$(mktemp -u)"; unset __tmp
  CONFIRM_ANSWER=""
  ask_yn CONFIRM_ANSWER "$1" "${2:-no}"
  answer="$CONFIRM_ANSWER"
  [[ "$answer" == "yes" ]]
}

# ---------- прочее ----------
detect_public_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -n1)"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "$ip"
}

is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

service_exists() { systemctl list-unit-files --type=service 2>/dev/null | grep -q "^$1\.service"; }

svc_restart() {
  local s="$1"
  run systemctl enable "$s" || true
  run systemctl restart "$s" || die "Не удалось запустить службу $s. Проверьте: systemctl status $s"
  ok "Служба $s запущена"
}
