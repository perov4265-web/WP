#!/usr/bin/env bash
# lib/screen.sh — экран установки.
#
# Сверху остаётся рамка с параметрами установки, снизу — прогресс-бар,
# название текущего этапа и строка пояснений. Всё это обновляется на месте,
# ничего не прокручивается: подробности пишутся в журнал установки.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные используются в соседних модулях

SCREEN_ACTIVE=0          # 0 — выключен, 1 — рисуем, 2 — временно приостановлен
SCREEN_COLS=80
SCREEN_ROWS=24
SCREEN_W=74
BOX_HEIGHT=0
PHASE_ROW=0
BAR_ROW=0
STATUS_ROW=0
PROGRESS_CUR=0
PROGRESS_TOTAL=1
PROGRESS_DONE=0
PROGRESS_NAME="Подготовка"
SCREEN_TITLE="Установка WordPress"
SCREEN_PARAM_LINES=()
SCREEN_WARNINGS=()

# Символы псевдографики (заменяются на ASCII, если терминал не в UTF-8)
B_TL='┌'; B_TR='┐'; B_BL='└'; B_BR='┘'; B_H='─'; B_V='│'
B_FULL='█'; B_EMPTY='░'; B_ARROW='›'

screen_charset() {
  local cm
  cm="$(locale charmap 2>/dev/null || echo C)"
  cm="${cm//-/}"
  if [[ "${cm^^}" != *"UTF8"* ]]; then
    B_TL='+'; B_TR='+'; B_BL='+'; B_BR='+'; B_H='-'; B_V='|'
    B_FULL='#'; B_EMPTY='.'; B_ARROW='>'
  fi
}

screen_term_size() {
  local size
  if command -v tput >/dev/null 2>&1; then
    SCREEN_COLS="$(tput cols 2>/dev/null || echo 80)"
    SCREEN_ROWS="$(tput lines 2>/dev/null || echo 24)"
  elif size="$(stty size 2>/dev/null)"; then
    SCREEN_ROWS="${size%% *}"; SCREEN_COLS="${size##* }"
  fi
  [[ "$SCREEN_COLS" =~ ^[0-9]+$ ]] || SCREEN_COLS=80
  [[ "$SCREEN_ROWS" =~ ^[0-9]+$ ]] || SCREEN_ROWS=24
  SCREEN_W=$(( SCREEN_COLS - 2 ))
  (( SCREEN_W > 76 )) && SCREEN_W=76
  (( SCREEN_W < 40 )) && SCREEN_W=40
}

screen_on() { [[ "$SCREEN_ACTIVE" == "1" ]]; }

screen_supported() {
  [[ "${PLAIN_OUTPUT:-0}" != "1" ]] || return 1
  [[ "${VERBOSE:-0}" != "1" ]] || return 1
  [[ -t 1 ]] || return 1
  [[ "${TERM:-dumb}" != "dumb" ]] || return 1
  return 0
}

# ------------------------------------------------------------------ рисование
_rep() { # _rep СИМВОЛ КОЛИЧЕСТВО
  local c="$1" n="$2" s=""
  while (( n-- > 0 )); do s+="$c"; done
  printf '%s' "$s"
}

_fit() { # обрезать строку до ширины
  local s="$1" w="$2"
  if (( ${#s} > w )); then printf '%s…' "${s:0:$(( w - 1 ))}"; else printf '%s' "$s"; fi
}

_at() { printf '\033[%d;1H\033[2K' "$1"; }   # перейти на строку и очистить её

screen_draw_box() {
  local inner=$(( SCREEN_W - 2 )) title=" ${SCREEN_TITLE} " line i
  _at 1
  printf '%s%s%s%s%s%s\n' "$C_BLUE" "$B_TL" "$B_H" "$title" \
    "$(_rep "$B_H" $(( inner - ${#title} - 1 )))" "${B_TR}${C_RESET}"
  i=2
  for line in "${SCREEN_PARAM_LINES[@]}"; do
    _at "$i"
    printf '%s%s%s %s%s%s\n' "$C_BLUE" "$B_V" "$C_RESET" \
      "$(_fit "$line" $(( inner - 2 )))" \
      "$(_rep ' ' $(( inner - 2 - ${#line} > 0 ? inner - 2 - ${#line} : 0 )))" \
      "${C_BLUE}${B_V}${C_RESET}"
    i=$(( i + 1 ))
  done
  _at "$i"
  printf '%s%s%s%s%s\n' "$C_BLUE" "$B_BL" "$(_rep "$B_H" "$inner")" "$B_BR" "$C_RESET"
}

screen_draw_progress() {
  screen_on || return 0
  local pct barw filled
  if (( PROGRESS_TOTAL > 0 )); then
    pct=$(( PROGRESS_CUR * 100 / PROGRESS_TOTAL ))
  else
    pct=0
  fi
  (( pct > 99 )) && pct=99
  (( PROGRESS_DONE == 1 )) && pct=100

  _at "$PHASE_ROW"
  printf '  %sЭтап %d из %d%s  %s%s%s' \
    "$C_DIM" "$PROGRESS_CUR" "$PROGRESS_TOTAL" "$C_RESET" \
    "$C_BOLD" "$(_fit "$PROGRESS_NAME" $(( SCREEN_W - 20 )))" "$C_RESET"

  barw=$(( SCREEN_W - 8 ))
  filled=$(( pct * barw / 100 ))
  _at "$BAR_ROW"
  printf '  %s%s%s%s%s %3d%%' \
    "$C_GREEN" "$(_rep "$B_FULL" "$filled")" "$C_DIM" \
    "$(_rep "$B_EMPTY" $(( barw - filled )))" "$C_RESET" "$pct"
}

screen_status() { # строка пояснения, всегда на одном и том же месте
  screen_on || return 1
  _at "$STATUS_ROW"
  printf '  %s%s %s%s' "$C_DIM" "$B_ARROW" "$(_fit "$*" $(( SCREEN_W - 4 )))" "$C_RESET"
}

screen_status_ok() {
  screen_on || return 1
  _at "$STATUS_ROW"
  printf '  %s✓%s %s' "$C_GREEN" "$C_RESET" "$(_fit "$*" $(( SCREEN_W - 4 )))"
}

screen_status_warn() {
  screen_on || return 1
  _at "$STATUS_ROW"
  printf '  %s!%s %s' "$C_YELLOW" "$C_RESET" "$(_fit "$*" $(( SCREEN_W - 4 )))"
}

# --------------------------------------------------------------- жизненный цикл
# screen_start ВСЕГО_ЭТАПОВ "строка параметров" ...
screen_start() {
  PROGRESS_TOTAL="$1"; shift
  screen_supported || return 1
  screen_charset
  screen_term_size
  SCREEN_PARAM_LINES=("$@")

  local need=$(( ${#SCREEN_PARAM_LINES[@]} + 2 + 5 ))
  if (( SCREEN_ROWS < need )); then
    log "[SCRN] терминал слишком мал (${SCREEN_COLS}x${SCREEN_ROWS}, нужно ${need} строк) — обычный вывод"
    return 1
  fi

  SCREEN_ACTIVE=1
  PROGRESS_CUR=0
  PROGRESS_DONE=0
  BOX_HEIGHT=$(( ${#SCREEN_PARAM_LINES[@]} + 2 ))
  PHASE_ROW=$(( BOX_HEIGHT + 2 ))
  BAR_ROW=$(( PHASE_ROW + 1 ))
  STATUS_ROW=$(( BAR_ROW + 1 ))

  printf '\033[2J\033[H\033[?25l'          # очистить экран, курсор наверх и спрятать
  screen_draw_box
  screen_draw_progress
  screen_status "подготовка…"
  return 0
}

# Следующий этап: обновляет заголовок и прогресс-бар
progress_next() {
  PROGRESS_NAME="$1"
  PROGRESS_CUR=$(( PROGRESS_CUR + 1 ))
  (( PROGRESS_CUR > PROGRESS_TOTAL )) && PROGRESS_TOTAL="$PROGRESS_CUR"
  screen_draw_progress
}

# Временно освободить экран (интерактивный вопрос, вывод ошибки)
screen_pause() {
  [[ "$SCREEN_ACTIVE" == "1" ]] || return 0
  SCREEN_ACTIVE=2
  printf '\033[%d;1H\033[?25h\n' "$(( STATUS_ROW + 1 ))"
}

screen_resume() {
  [[ "$SCREEN_ACTIVE" == "2" ]] || return 0
  SCREEN_ACTIVE=1
  screen_term_size
  printf '\033[2J\033[H\033[?25l'
  screen_draw_box
  screen_draw_progress
}

# Вернуть терминал в обычное состояние
screen_restore() {
  [[ "$SCREEN_ACTIVE" == "0" ]] && return 0
  local row=$(( STATUS_ROW + 2 ))
  SCREEN_ACTIVE=0
  printf '\033[?25h\033[%d;1H\n' "$row"
}

# Успешное завершение: дорисовать 100 % и освободить экран
screen_finish() {
  if screen_on; then
    PROGRESS_DONE=1
    PROGRESS_CUR="$PROGRESS_TOTAL"
    PROGRESS_NAME="Готово"
    screen_draw_progress
    screen_status_ok "установка завершена"
    screen_restore
  fi
  if [[ ${#SCREEN_WARNINGS[@]} -gt 0 ]]; then
    printf '\n%sПредупреждения во время установки:%s\n' "$C_YELLOW" "$C_RESET"
    local w
    for w in "${SCREEN_WARNINGS[@]}"; do printf '  ! %s\n' "$w"; done
  fi
}
