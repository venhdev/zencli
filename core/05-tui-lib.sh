#!/usr/bin/env bash
# ==============================================================================
# core/05-tui-lib.sh - Standardized Pure-Bash TUI Component & Event Engine
# ==============================================================================
# Provides reusable terminal raw-mode control, normalized keyboard events,
# ANSI table rendering, and interactive modal dialogs across dotfiles utilities.
# ==============================================================================

# ANSI Color & Style Palettes
_TUI_RESET="\033[0m"
_TUI_BOLD="\033[1m"
_TUI_DIM="\033[2m"
_TUI_CYAN="\033[1;36m"
_TUI_BLUE="\033[1;34m"
_TUI_GREEN="\033[1;32m"
_TUI_YELLOW="\033[1;33m"
_TUI_RED="\033[1;31m"
_TUI_GRAY="\033[90m"
_TUI_WHITE="\033[37m"

_TUI_ORIG_STTY=""
_TUI_IS_ACTIVE=0
_TUI_COLS=80
_TUI_LINES=24
_TUI_DIRTY=0

# Check if TTY is interactive and writable
_tui_is_interactive() {
  { exec 3<>/dev/tty; } 2>/dev/null || return 1
  exec 3>&-
  return 0
}

# Dynamic screen dimension detection (pure-Bash checkwinsize with tput fallback)
_tui_update_dimensions() {
  if [[ -n "${_TUI_FORCE_COLS:-}" && -n "${_TUI_FORCE_LINES:-}" ]]; then
    _TUI_COLS="$_TUI_FORCE_COLS"
    _TUI_LINES="$_TUI_FORCE_LINES"
    return 0
  fi

  shopt -s checkwinsize 2>/dev/null || true
  (:;:) 2>/dev/null || true
  _TUI_COLS="${COLUMNS:-}"
  _TUI_LINES="${LINES:-}"
  if [[ -z "$_TUI_COLS" || "$_TUI_COLS" -le 0 ]]; then
    _TUI_COLS="$(tput cols 2>/dev/null || echo 80)"
  fi
  if [[ -z "$_TUI_LINES" || "$_TUI_LINES" -le 0 ]]; then
    _TUI_LINES="$(tput lines 2>/dev/null || echo 24)"
  fi
}

# Signal handler for window size change (SIGWINCH)
_tui_on_winch() {
  _tui_update_dimensions
  _TUI_DIRTY=1
}

# Zero-fork string repetition using pure-Bash printf -v
_tui_repeat_char() {
  local char="${1:-─}"
  local count="${2:-0}"
  (( count <= 0 )) && return 0
  local out=""
  printf -v out '%*s' "$count" ''
  printf "%s" "${out// /$char}"
}

# Zero-fork string truncation with ellipsis
_tui_truncate() {
  local str="$1"
  local max_len="$2"
  if (( ${#str} > max_len )); then
    if (( max_len > 3 )); then
      printf "%s..." "${str:0:$((max_len - 3))}"
    else
      printf "%s" "${str:0:$max_len}"
    fi
  else
    printf "%s" "$str"
  fi
}

# Enter TUI Raw Mode
_tui_enter() {
  if [[ -z "${_TUI_ORIG_STTY:-}" ]]; then
    _TUI_ORIG_STTY="$(stty -g < /dev/tty 2>/dev/null || true)"
  fi
  _tui_update_dimensions
  stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null || true
  # Alternate screen buffer (\033[?1049h), disable auto-wrap (\033[?7l), hide cursor (\033[?25l)
  printf "\033[?1049h\033[?7l\033[?25l" >/dev/tty 2>/dev/null || true
  _TUI_IS_ACTIVE=1
  trap '_tui_sigint' INT
  trap '_tui_sigterm' TERM
  trap '_tui_exit' EXIT
  trap '_tui_on_winch' WINCH
}

# Signal handler for SIGINT (Ctrl+C)
_tui_sigint() {
  _tui_exit
  printf "\n" >/dev/tty 2>/dev/null || true
  trap - INT EXIT TERM WINCH
  kill -s INT $$ 2>/dev/null || exit 130
}

# Signal handler for SIGTERM
_tui_sigterm() {
  _tui_exit
  printf "\n" >/dev/tty 2>/dev/null || true
  trap - TERM EXIT INT WINCH
  kill -s TERM $$ 2>/dev/null || exit 143
}

# Exit TUI Raw Mode and Restore Terminal State
_tui_exit() {
  # Show cursor (\033[?25h), restore auto-wrap (\033[?7h), exit alternate screen buffer (\033[?1049l)
  printf "\033[?25h\033[?7h\033[?1049l" >/dev/tty 2>/dev/null || true
  if [[ -n "${_TUI_ORIG_STTY:-}" ]]; then
    stty "$_TUI_ORIG_STTY" < /dev/tty 2>/dev/null || true
  fi
  _TUI_IS_ACTIVE=0
  trap - WINCH INT TERM EXIT
}

# Clear screen and return cursor to home (0,0)
_tui_clear() {
  printf "\033[H\033[2J" >/dev/tty 2>/dev/null || true
}

# Read and Normalize Keyboard Event from TTY
# Output variable names:
#   UP, DOWN, LEFT, RIGHT, SPACE, ENTER, ESC, QUIT, REDRAW,
#   ALL, INSTALL, UPDATE, DELETE, INFO, or CHAR:<c>
_tui_read_key() {
  local _out_var="$1"
  local key=""

  if (( _TUI_DIRTY )); then
    _TUI_DIRTY=0
    eval "$_out_var='REDRAW'"
    return
  fi

  if ! IFS= read -rsn1 key < /dev/tty 2>/dev/null; then
    if (( _TUI_DIRTY )); then
      _TUI_DIRTY=0
      eval "$_out_var='REDRAW'"
      return
    fi
    eval "$_out_var='QUIT'"
    return
  fi

  if [[ "$key" == $'\x1b' ]]; then
    local seq=""
    read -rsn2 -t 0.1 seq < /dev/tty 2>/dev/null || seq=""
    case "$seq" in
      "[A"|"OA") eval "$_out_var='UP'" ;;
      "[B"|"OB") eval "$_out_var='DOWN'" ;;
      "[C"|"OC") eval "$_out_var='RIGHT'" ;;
      "[D"|"OD") eval "$_out_var='LEFT'" ;;
      "")        eval "$_out_var='ESC'" ;;
      *)         eval "$_out_var='ESC'" ;;
    esac
  elif [[ "$key" == "k" || "$key" == "K" ]]; then
    eval "$_out_var='UP'"
  elif [[ "$key" == "j" || "$key" == "J" ]]; then
    eval "$_out_var='DOWN'"
  elif [[ "$key" == " " ]]; then
    eval "$_out_var='SPACE'"
  elif [[ "$key" == "a" || "$key" == "A" ]]; then
    eval "$_out_var='ALL'"
  elif [[ "$key" == "i" || "$key" == "I" ]]; then
    eval "$_out_var='INSTALL'"
  elif [[ "$key" == "u" || "$key" == "U" ]]; then
    eval "$_out_var='UPDATE'"
  elif [[ "$key" == "d" || "$key" == "D" ]]; then
    eval "$_out_var='DELETE'"
  elif [[ "$key" == "?" || "$key" == "o" || "$key" == "O" ]]; then
    eval "$_out_var='INFO'"
  elif [[ "$key" == "q" || "$key" == "Q" || "$key" == $'\x03' || "$key" == $'\x04' ]]; then
    eval "$_out_var='QUIT'"
  elif [[ "$key" == "" || "$key" == $'\r' || "$key" == $'\n' ]]; then
    eval "$_out_var='ENTER'"
  else
    eval "$_out_var=\"CHAR:$key\""
  fi
}

# Render Standard Header with dynamic width
_tui_draw_header() {
  local title="$1"
  local subtitle="${2:-}"
  _tui_update_dimensions
  local width="${_TUI_COLS:-80}"
  (( width > 80 )) && width=80
  (( width < 36 )) && width=36
  local divider
  divider="$(_tui_repeat_char "─" "$width")"

  printf "${_TUI_CYAN}${_TUI_BOLD}=== %s ===${_TUI_RESET}\n" "$title" >/dev/tty
  if [[ -n "$subtitle" ]]; then
    printf "${_TUI_BLUE}%s${_TUI_RESET}\n" "$subtitle" >/dev/tty
  fi
  printf "${_TUI_GRAY}%s${_TUI_RESET}\n\n" "$divider" >/dev/tty
}

# Render Standard Footer with dynamic width
_tui_draw_footer() {
  local help_text="$1"
  _tui_update_dimensions
  local width="${_TUI_COLS:-80}"
  (( width > 80 )) && width=80
  (( width < 36 )) && width=36
  local divider
  divider="$(_tui_repeat_char "─" "$width")"

  printf "\n${_TUI_GRAY}%s${_TUI_RESET}\n" "$divider" >/dev/tty
  if (( width < 52 )); then
    printf "${_TUI_GRAY}%s${_TUI_RESET}\n" "[↑/↓] Move [Space] Select [i] Install" >/dev/tty
    printf "${_TUI_GRAY}%s${_TUI_RESET}\n" "[u] Update [d] Remove [q] Quit" >/dev/tty
  elif (( ${#help_text} > width )); then
    printf "${_TUI_GRAY}%s${_TUI_RESET}\n" "$(_tui_truncate "$help_text" "$width")" >/dev/tty
  else
    printf "${_TUI_GRAY}%s${_TUI_RESET}\n" "$help_text" >/dev/tty
  fi
}

# Render Modal Dialog Box with responsive width
_tui_modal_box() {
  local title="$1"
  local -n _lines="$2"
  _tui_update_dimensions
  local width=$(( _TUI_COLS - 4 ))
  (( width > 80 )) && width=80
  (( width < 36 )) && width=36
  local inner_width=$((width - 4))

  _tui_clear

  local title_part="┌─[ $title ]"
  local pad_len=$((width - ${#title_part} - 1))
  (( pad_len < 0 )) && pad_len=0
  local top_dashes
  top_dashes="$(_tui_repeat_char "─" "$pad_len")"
  printf "${_TUI_CYAN}${_TUI_BOLD}%s%s┐${_TUI_RESET}\n" "$title_part" "$top_dashes" >/dev/tty

  local line
  for line in "${_lines[@]}"; do
    local trunc_line
    trunc_line="$(_tui_truncate "$line" "$inner_width")"
    printf "${_TUI_CYAN}│${_TUI_RESET} %-*s ${_TUI_CYAN}│${_TUI_RESET}\n" "$inner_width" "$trunc_line" >/dev/tty
  done

  local div_dashes
  div_dashes="$(_tui_repeat_char "─" "$((width - 2))")"
  printf "${_TUI_CYAN}├%s┤${_TUI_RESET}\n" "$div_dashes" >/dev/tty
  local return_hint="  [Press any key or Esc/q to return]"
  local trunc_hint
  trunc_hint="$(_tui_truncate "$return_hint" "$inner_width")"
  printf "${_TUI_CYAN}│${_TUI_RESET} ${_TUI_GRAY}%-*s${_TUI_RESET} ${_TUI_CYAN}│${_TUI_RESET}\n" "$inner_width" "$trunc_hint" >/dev/tty
  printf "${_TUI_CYAN}└%s┘${_TUI_RESET}\n" "$div_dashes" >/dev/tty

  local dummy=""
  IFS= read -rsn1 dummy < /dev/tty 2>/dev/null || true
  if [[ "$dummy" == $'\x1b' ]]; then
    read -rsn2 -t 0.1 dummy < /dev/tty 2>/dev/null || true
  fi
}

# Prompt user for confirmation with safe temporary cooked terminal
_tui_confirm_prompt() {
  local prompt_msg="$1"
  local default_val="${2:-N}"

  local hint="[y/N]"
  [[ "$default_val" == "Y" || "$default_val" == "y" ]] && hint="[Y/n]"

  printf "\033[?25h" >/dev/tty 2>/dev/null || true
  if [[ -n "${_TUI_ORIG_STTY:-}" ]]; then
    stty "$_TUI_ORIG_STTY" < /dev/tty 2>/dev/null || true
  fi

  local answer=""
  printf "%s %s: " "$prompt_msg" "$hint" >/dev/tty
  IFS= read -r answer < /dev/tty || answer=""

  if (( _TUI_IS_ACTIVE )); then
    stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null || true
    printf "\033[?25l" >/dev/tty 2>/dev/null || true
  fi

  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    [Nn]|[Nn][Oo]) return 1 ;;
    "")
      [[ "$default_val" == "Y" || "$default_val" == "y" ]] && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}
