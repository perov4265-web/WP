#!/usr/bin/env bash
# lib/ui.sh — псевдографический интерфейс (whiptail/dialog) с откатом на текстовый ввод.
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях

UI_MODE="${UI_MODE:-auto}"     # auto | tui | text
DIALOG_BIN=""
UI_TITLE="wp-autoinstall — установка WordPress"

ui_init() {
  case "$UI_MODE" in
    text) DIALOG_BIN=""; return 0 ;;
  esac
  if [[ "$ASSUME_YES" == "1" ]] || [[ ! -t 0 ]] || [[ ! -t 1 ]] || [[ "${TERM:-dumb}" == "dumb" ]]; then
    UI_MODE="text"; DIALOG_BIN=""; return 0
  fi
  if require_cmd whiptail; then DIALOG_BIN="whiptail"
  elif require_cmd dialog; then DIALOG_BIN="dialog"
  else
    # whiptail — маленький пакет, ставим его ради псевдографического интерфейса
    printf '  %sПодготовка интерфейса…%s\n' "$C_DIM" "$C_RESET"
    apt_install whiptail >/dev/null 2>&1 || true
    require_cmd whiptail && DIALOG_BIN="whiptail"
  fi
  if [[ -n "$DIALOG_BIN" ]]; then
    UI_MODE="tui"
    export NEWT_COLORS='
root=,blue
window=,lightgray
border=blue,lightgray
title=blue,lightgray
textbox=black,lightgray
button=white,blue
actbutton=white,cyan
entry=black,white
listbox=black,lightgray
actlistbox=white,blue
checkbox=black,lightgray
actcheckbox=white,blue
'
  else
    UI_MODE="text"
  fi
}

# Высота окна по количеству строк текста, но не больше высоты терминала
_ui_height() {
  local text="$1" extra="${2:-8}" lines rows h
  lines="$(printf '%s\n' "$text" | wc -l)"
  rows="$( (tput lines 2>/dev/null || echo 24) )"
  h=$(( lines + extra ))
  (( h > rows - 2 )) && h=$(( rows - 2 ))
  (( h < 8 )) && h=8
  printf '%s' "$h"
}

# Нужна ли прокрутка (текст не помещается целиком)
_ui_scroll() {
  local text="$1" extra="${2:-8}" lines rows
  lines="$(printf '%s\n' "$text" | wc -l)"
  rows="$( (tput lines 2>/dev/null || echo 24) )"
  (( lines + extra > rows - 2 ))
}

ui_cancelled() { die "Установка отменена пользователем."; }

# ---------------------------------------------------------------- сообщения
ui_msg() { # ui_msg "текст"
  if [[ "$UI_MODE" == "tui" ]]; then
    local h scroll=()
    h="$(_ui_height "$1" 7)"
    _ui_scroll "$1" 7 && scroll=(--scrolltext)
    "$DIALOG_BIN" --title "$UI_TITLE" "${scroll[@]}" --msgbox "$1" "$h" 76 3>&1 1>&2 2>&3 || true
  else
    printf '\n%s\n' "$1"
  fi
}

ui_welcome() {
  local text
  text="Скрипт установит и настроит на этом сервере:

  • веб-сервер (Nginx или Apache)
  • PHP-FPM с расширениями для WordPress
  • MariaDB или MySQL
  • WordPress — полностью готовый к работе

Дополнительно, по вашему выбору: phpMyAdmin, бесплатный
SSL-сертификат Let's Encrypt, брандмауэр UFW и fail2ban.

Сейчас будет задано несколько вопросов о параметрах сайта.
Пустой ответ = значение по умолчанию."
  if [[ "$UI_MODE" == "tui" ]]; then
    local h scroll=()
    h="$(_ui_height "$text" 6)"
    _ui_scroll "$text" 6 && scroll=(--scrolltext)
    "$DIALOG_BIN" --title "$UI_TITLE" --yes-button "Продолжить" --no-button "Выход" "${scroll[@]}" \
      --yesno "$text" "$h" 74 3>&1 1>&2 2>&3 || ui_cancelled
  else
    printf '\n%s%s%s\n%s\n' "$C_BOLD" "$UI_TITLE" "$C_RESET" "$text"
  fi
}

# ---------------------------------------------------------------- поле ввода
# ui_input ПЕРЕМЕННАЯ "Вопрос" "по умолчанию" [валидатор]
ui_input() {
  local __name="$1" prompt="$2" def="${3:-}" validator="${4:-}" value msg
  local current="${!__name-}"
  [[ -n "$current" ]] && def="$current"

  if [[ "$UI_MODE" != "tui" ]]; then
    ask "$__name" "$prompt" "$def" "$validator"; return
  fi

  while true; do
    value="$("$DIALOG_BIN" --title "$UI_TITLE" --inputbox "$prompt" 11 74 "$def" 3>&1 1>&2 2>&3)" || ui_cancelled
    value="${value:-$def}"
    if [[ -n "$validator" ]] && declare -F "$validator" >/dev/null; then
      if msg="$("$validator" "$value")"; then printf -v "$__name" '%s' "$value"; return 0; fi
      ui_msg "Ошибка: ${msg:-некорректное значение}"
      continue
    fi
    [[ -n "$value" ]] || { ui_msg "Значение не может быть пустым."; continue; }
    printf -v "$__name" '%s' "$value"; return 0
  done
}

# ui_secret ПЕРЕМЕННАЯ "Вопрос" [валидатор]
ui_secret() {
  local __name="$1" prompt="$2" validator="${3:-v_dbpass}" a b msg
  local current="${!__name-}"
  if [[ -n "$current" ]]; then
    if msg="$("$validator" "$current")"; then return 0; fi
    die "Значение $__name не проходит проверку: $msg"
  fi

  if [[ "$UI_MODE" != "tui" ]]; then
    ask_secret "$__name" "$prompt" "$validator"; return
  fi

  while true; do
    a="$("$DIALOG_BIN" --title "$UI_TITLE" \
      --passwordbox "${prompt}\n\n(оставьте поле пустым — пароль будет создан автоматически)" 12 74 3>&1 1>&2 2>&3)" || ui_cancelled
    if [[ -z "$a" ]]; then
      a="$(rand_pass 20)"
      ui_msg "Сгенерирован пароль:\n\n    ${a}\n\nОн будет показан в конце установки и сохранён в файл с доступами."
      printf -v "$__name" '%s' "$a"; return 0
    fi
    if ! msg="$("$validator" "$a")"; then ui_msg "Ошибка: ${msg}"; continue; fi
    b="$("$DIALOG_BIN" --title "$UI_TITLE" --passwordbox "Повторите пароль:" 10 74 3>&1 1>&2 2>&3)" || ui_cancelled
    [[ "$a" == "$b" ]] || { ui_msg "Пароли не совпадают, попробуйте ещё раз."; continue; }
    printf -v "$__name" '%s' "$a"; return 0
  done
}

# ui_yesno ПЕРЕМЕННАЯ "Вопрос" yes|no
ui_yesno() {
  local __name="$1" prompt="$2" def="${3:-no}"
  local current="${!__name-}"
  if [[ -n "$current" ]]; then
    case "${current,,}" in
      1|y|yes|true|да) printf -v "$__name" '%s' yes; return 0 ;;
      0|n|no|false|нет) printf -v "$__name" '%s' no; return 0 ;;
    esac
  fi
  if [[ "$UI_MODE" != "tui" ]]; then ask_yn "$__name" "$prompt" "$def"; return; fi

  local extra=()
  [[ "$def" == "no" ]] && extra=(--defaultno)
  if "$DIALOG_BIN" --title "$UI_TITLE" --yes-button "Да" --no-button "Нет" "${extra[@]}" \
      --yesno "$prompt" 11 74 3>&1 1>&2 2>&3; then
    printf -v "$__name" '%s' yes
  else
    printf -v "$__name" '%s' no
  fi
}

# ui_menu ПЕРЕМЕННАЯ "Вопрос" "значение по умолчанию" ВАЛИДАТОР "знач|подпись" ...
# Пункт "custom" добавляется автоматически: ввод своего значения.
ui_menu() {
  local __name="$1" prompt="$2" def="$3" validator="$4"; shift 4
  local current="${!__name-}"
  [[ -n "$current" ]] && def="$current"

  if [[ "$ASSUME_YES" == "1" ]]; then
    local msg
    if [[ -n "$validator" ]] && declare -F "$validator" >/dev/null; then
      if ! msg="$("$validator" "$def")"; then
        die "Значение ${__name}='${def}' не проходит проверку: ${msg:-некорректное значение}"
      fi
    fi
    printf -v "$__name" '%s' "$def"; return 0
  fi

  local -a values=() labels=()
  local pair
  for pair in "$@"; do
    values+=("${pair%%|*}")
    labels+=("${pair#*|}")
  done

  if [[ "$UI_MODE" == "tui" ]]; then
    local -a items=()
    local i
    for i in "${!values[@]}"; do items+=("${values[$i]}" "${labels[$i]}"); done
    items+=("custom" "Ввести своё значение…")
    local choice
    choice="$("$DIALOG_BIN" --title "$UI_TITLE" --default-item "$def" \
      --menu "$prompt" 20 74 $(( ${#values[@]} + 1 )) "${items[@]}" 3>&1 1>&2 2>&3)" || ui_cancelled
    if [[ "$choice" == "custom" ]]; then
      unset "$__name"; ui_input "$__name" "$prompt (своё значение)" "$def" "$validator"; return 0
    fi
    printf -v "$__name" '%s' "$choice"; return 0
  fi

  # текстовый режим
  local i num
  printf '\n%s?%s %s\n' "$C_BLUE" "$C_RESET" "$prompt"
  for i in "${!values[@]}"; do
    local mark=" "; [[ "${values[$i]}" == "$def" ]] && mark="*"
    printf '  %s%s%2d)%s %-10s %s%s%s\n' "$C_GREEN" "$mark" "$((i+1))" "$C_RESET" "${values[$i]}" "$C_DIM" "${labels[$i]}" "$C_RESET"
  done
  printf '   %s%2d)%s свой вариант\n' "$C_BOLD" "$(( ${#values[@]} + 1 ))" "$C_RESET"
  while true; do
    read -r -p "$(printf '   Выбор %s[%s]%s: ' "$C_DIM" "$def" "$C_RESET")" num || die "Ввод прерван (нет данных на stdin)."
    if [[ -z "$num" ]]; then printf -v "$__name" '%s' "$def"; return 0; fi
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#values[@]} )); then
      printf -v "$__name" '%s' "${values[$((num-1))]}"; return 0
    fi
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num == ${#values[@]} + 1 )); then
      unset "$__name"; ask "$__name" "$prompt (своё значение)" "$def" "$validator"; return 0
    fi
    err "введите номер от 1 до $(( ${#values[@]} + 1 ))"
  done
}

# ui_checklist "Вопрос" "ПЕРЕМЕННАЯ|Тег|Описание|on|off" ...
# Тег — короткое имя пункта, которое видит пользователь; переменная получает yes/no.
ui_checklist() {
  local prompt="$1"; shift
  local -a names=() tags=() labels=() states=()
  local pair name tag label state
  for pair in "$@"; do
    IFS='|' read -r name tag label state <<< "$pair"
    names+=("$name"); tags+=("$tag"); labels+=("$label"); states+=("$state")
  done

  if [[ "$UI_MODE" != "tui" ]]; then
    local i def
    for i in "${!names[@]}"; do
      def="no"; [[ "${states[$i]}" == "on" ]] && def="yes"
      ask_yn "${names[$i]}" "${labels[$i]}" "$def"
    done
    return 0
  fi

  local -a items=()
  local i
  for i in "${!names[@]}"; do
    items+=("${tags[$i]}" "${labels[$i]}" "${states[$i]}")
  done

  local selected
  selected="$("$DIALOG_BIN" --title "$UI_TITLE" --separate-output \
    --checklist "${prompt}\n(пробел — отметить или снять, Tab — перейти к кнопкам)" \
    $(( ${#names[@]} + 9 )) 78 "${#names[@]}" "${items[@]}" 3>&1 1>&2 2>&3)" || ui_cancelled

  for i in "${!names[@]}"; do
    if printf '%s\n' "$selected" | grep -qxF "${tags[$i]}"; then
      printf -v "${names[$i]}" '%s' yes
    else
      printf -v "${names[$i]}" '%s' no
    fi
  done
}

# Итоговая сводка перед установкой
ui_confirm_summary() {
  local text="$1"
  if [[ "$UI_MODE" == "tui" ]]; then
    local h scroll=()
    h="$(_ui_height "$text" 9)"
    _ui_scroll "$text" 9 && scroll=(--scrolltext)
    "$DIALOG_BIN" --title "$UI_TITLE" --yes-button "Установить" --no-button "Отмена" "${scroll[@]}" \
      --yesno "$text" "$h" 76 3>&1 1>&2 2>&3 || ui_cancelled
  else
    printf '\n%s\n' "$text"
    [[ "$ASSUME_YES" == "1" ]] && return 0
    confirm "Начать установку с этими параметрами?" "yes" || ui_cancelled
  fi
}
