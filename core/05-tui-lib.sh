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
  [[ "${_TUI_FORCE_NON_INTERACTIVE:-0}" == "1" ]] && return 1
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
  local out_var="${3:-}"
  local out=""
  if (( count > 0 )); then
    printf -v out '%*s' "$count" ''
    out="${out// /$char}"
  fi
  if [[ -n "$out_var" ]]; then
    printf -v "$out_var" "%s" "$out"
  else
    printf "%s" "$out"
  fi
}

# Zero-fork string truncation with ellipsis
_tui_truncate() {
  local str="$1"
  local max_len="$2"
  local out_var="${3:-}"
  local res=""
  if (( ${#str} > max_len )); then
    if (( max_len > 3 )); then
      res="${str:0:$((max_len - 3))}..."
    else
      res="${str:0:$max_len}"
    fi
  else
    res="$str"
  fi

  if [[ -n "$out_var" ]]; then
    printf -v "$out_var" "%s" "$res"
  else
    printf "%s" "$res"
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
  local __trk_out_var="$1"
  local __trk_key=""

  if (( _TUI_DIRTY )); then
    _TUI_DIRTY=0
    eval "$__trk_out_var='REDRAW'"
    return
  fi

  if ! IFS= read -rsn1 __trk_key < /dev/tty 2>/dev/null; then
    if (( _TUI_DIRTY )); then
      _TUI_DIRTY=0
      eval "$__trk_out_var='REDRAW'"
      return
    fi
    eval "$__trk_out_var='QUIT'"
    return
  fi

  if [[ "$__trk_key" == $'\x1b' ]]; then
    local __trk_seq=""
    read -rsn2 -t 0.1 __trk_seq < /dev/tty 2>/dev/null || __trk_seq=""
    case "$__trk_seq" in
      "[A"|"OA") eval "$__trk_out_var='UP'" ;;
      "[B"|"OB") eval "$__trk_out_var='DOWN'" ;;
      "[C"|"OC") eval "$__trk_out_var='RIGHT'" ;;
      "[D"|"OD") eval "$__trk_out_var='LEFT'" ;;
      "")        eval "$__trk_out_var='ESC'" ;;
      *)         eval "$__trk_out_var='ESC'" ;;
    esac
  elif [[ "$__trk_key" == "k" || "$__trk_key" == "K" ]]; then
    eval "$__trk_out_var='UP'"
  elif [[ "$__trk_key" == "j" || "$__trk_key" == "J" ]]; then
    eval "$__trk_out_var='DOWN'"
  elif [[ "$__trk_key" == " " ]]; then
    eval "$__trk_out_var='SPACE'"
  elif [[ "$__trk_key" == "q" || "$__trk_key" == "Q" || "$__trk_key" == $'\x03' || "$__trk_key" == $'\x04' ]]; then
    eval "$__trk_out_var='QUIT'"
  elif [[ "$__trk_key" == "" || "$__trk_key" == $'\r' || "$__trk_key" == $'\n' ]]; then
    eval "$__trk_out_var='ENTER'"
  else
    eval "$__trk_out_var=\"CHAR:$__trk_key\""
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
  local divider=""
  _tui_repeat_char "─" "$width" divider

  printf "${_TUI_CYAN}${_TUI_BOLD}=== %s ===${_TUI_RESET}\n" "$title" >/dev/tty
  if [[ -n "$subtitle" ]]; then
    printf "${_TUI_BLUE}%s${_TUI_RESET}\n" "$subtitle" >/dev/tty
  fi
  printf "${_TUI_GRAY}%s${_TUI_RESET}\n\n" "$divider" >/dev/tty
}

# Render Standard Footer with dynamic width
_tui_draw_footer() {
  local help_text="${1:-}"
  _tui_update_dimensions
  local width="${_TUI_COLS:-80}"
  (( width > 80 )) && width=80
  (( width < 36 )) && width=36
  local divider=""
  _tui_repeat_char "─" "$width" divider

  printf "\n${_TUI_GRAY}%s${_TUI_RESET}\n" "$divider" >/dev/tty
  if [[ -n "$help_text" && ${#help_text} -le width ]]; then
    printf "${_TUI_GRAY}%s${_TUI_RESET}\n" "$help_text" >/dev/tty
  elif (( width >= 72 )); then
    printf "${_TUI_GRAY}%s${_TUI_RESET}\n" "[↑/↓] Move  [Space] Select  [i] Install  [u] Update  [d] Remove  [?] Help  [q] Quit" >/dev/tty
  elif (( width >= 54 )); then
    printf "${_TUI_GRAY}%s${_TUI_RESET}\n" "[↑/↓] Move  [Space] Select  [i] Install  [?] Help  [q] Quit" >/dev/tty
  else
    printf "${_TUI_GRAY}%s${_TUI_RESET}\n" "[↑/↓] Move  [Space] Select  [?] Help  [q] Quit" >/dev/tty
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
  local top_dashes=""
  _tui_repeat_char "─" "$pad_len" top_dashes
  printf "${_TUI_CYAN}${_TUI_BOLD}%s%s┐${_TUI_RESET}\n" "$title_part" "$top_dashes" >/dev/tty

  local line
  for line in "${_lines[@]}"; do
    local trunc_line=""
    _tui_truncate "$line" "$inner_width" trunc_line
    local pad_spaces=$(( inner_width - ${#trunc_line} ))
    (( pad_spaces < 0 )) && pad_spaces=0
    local pad_str
    printf -v pad_str "%*s" "$pad_spaces" ""
    printf "${_TUI_CYAN}│${_TUI_RESET} %s%s ${_TUI_CYAN}│${_TUI_RESET}\n" "$trunc_line" "$pad_str" >/dev/tty
  done

  local div_dashes=""
  _tui_repeat_char "─" "$((width - 2))" div_dashes
  printf "${_TUI_CYAN}├%s┤${_TUI_RESET}\n" "$div_dashes" >/dev/tty
  local return_hint="  [Press any key or Esc/q to return]"
  local trunc_hint=""
  _tui_truncate "$return_hint" "$inner_width" trunc_hint
  local pad_hint_spaces=$(( inner_width - ${#trunc_hint} ))
  (( pad_hint_spaces < 0 )) && pad_hint_spaces=0
  local pad_hint_str
  printf -v pad_hint_str "%*s" "$pad_hint_spaces" ""
  printf "${_TUI_CYAN}│${_TUI_RESET} ${_TUI_GRAY}%s%s${_TUI_RESET} ${_TUI_CYAN}│${_TUI_RESET}\n" "$trunc_hint" "$pad_hint_str" >/dev/tty
  printf "${_TUI_CYAN}└%s┘${_TUI_RESET}\n" "$div_dashes" >/dev/tty

  local dummy=""
  IFS= read -rsn1 dummy < /dev/tty 2>/dev/null || true
  if [[ "$dummy" == $'\x1b' ]]; then
    read -rsn2 -t 0.1 dummy < /dev/tty 2>/dev/null || true
  fi
}

# Render Modal Confirmation Dialog Box (returns 0 on Y/Enter, 1 on N/Esc/q)
_tui_modal_confirm() {
  local title="$1"
  local -n _lines="$2"
  local prompt_hint="${3:-[Y/Enter] Proceed   [n/Esc/q] Cancel}"
  _tui_update_dimensions
  local width=$(( _TUI_COLS - 4 ))
  (( width > 80 )) && width=80
  (( width < 36 )) && width=36
  local inner_width=$((width - 4))

  _tui_clear

  local title_part="┌─[ $title ]"
  local pad_len=$((width - ${#title_part} - 1))
  (( pad_len < 0 )) && pad_len=0
  local top_dashes=""
  _tui_repeat_char "─" "$pad_len" top_dashes
  printf "${_TUI_CYAN}${_TUI_BOLD}%s%s┐${_TUI_RESET}\n" "$title_part" "$top_dashes" >/dev/tty

  local line
  for line in "${_lines[@]}"; do
    local trunc_line=""
    _tui_truncate "$line" "$inner_width" trunc_line
    local pad_spaces=$(( inner_width - ${#trunc_line} ))
    (( pad_spaces < 0 )) && pad_spaces=0
    local pad_str
    printf -v pad_str "%*s" "$pad_spaces" ""
    printf "${_TUI_CYAN}│${_TUI_RESET} %s%s ${_TUI_CYAN}│${_TUI_RESET}\n" "$trunc_line" "$pad_str" >/dev/tty
  done

  local div_dashes=""
  _tui_repeat_char "─" "$((width - 2))" div_dashes
  printf "${_TUI_CYAN}├%s┤${_TUI_RESET}\n" "$div_dashes" >/dev/tty
  local trunc_hint=""
  _tui_truncate "  $prompt_hint" "$inner_width" trunc_hint
  local pad_hint_spaces=$(( inner_width - ${#trunc_hint} ))
  (( pad_hint_spaces < 0 )) && pad_hint_spaces=0
  local pad_hint_str
  printf -v pad_hint_str "%*s" "$pad_hint_spaces" ""
  printf "${_TUI_CYAN}│${_TUI_RESET} ${_TUI_BOLD}%s%s${_TUI_RESET} ${_TUI_CYAN}│${_TUI_RESET}\n" "$trunc_hint" "$pad_hint_str" >/dev/tty
  printf "${_TUI_CYAN}└%s┘${_TUI_RESET}\n" "$div_dashes" >/dev/tty

  local dummy=""
  IFS= read -rsn1 dummy < /dev/tty 2>/dev/null || return 1
  if [[ "$dummy" == $'\x1b' ]]; then
    read -rsn2 -t 0.1 dummy < /dev/tty 2>/dev/null || true
    return 1
  fi
  case "$dummy" in
    [Yy]|""|$'\r'|$'\n') return 0 ;;
    *) return 1 ;;
  esac
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

# ==============================================================================
# UNIFIED TUI SELECTION ENGINES (Alternate Screen & Zero-Fork Event Loop)
# ==============================================================================

_tui_select_one() {
  local title="$1" subtitle="$2" selected_out="$3"
  shift 3
  local items=("$@")
  local count=${#items[@]}
  local cursor=0 key idx i

  # Pre-flight check
  if ! _tui_is_interactive; then
    printf -v "$selected_out" "%s" "0"
    return 0
  fi

  if [[ -n "${!selected_out:-}" ]]; then
    for ((idx=0; idx<count; idx++)); do
      if [[ "${items[idx]}" == "${!selected_out}" || "$idx" == "${!selected_out}" ]]; then
        cursor=$idx
        break
      fi
    done
  fi

  _tui_enter

  while true; do
    _tui_clear
    _tui_update_dimensions
    _tui_draw_header "$title" "$subtitle"

    local max_w=$(( _TUI_COLS - 4 ))
    (( max_w > 80 )) && max_w=80
    (( max_w < 36 )) && max_w=36

    for ((i=0; i<count; i++)); do
      local item_text=""
      _tui_truncate "${items[i]}" "$((max_w - 6))" item_text
      if (( i == cursor )); then
        printf "  ${_TUI_GREEN}${_TUI_BOLD}> %s${_TUI_RESET}\n" "$item_text" >/dev/tty
      else
        printf "    %s\n" "$item_text" >/dev/tty
      fi
    done

    _tui_draw_footer "[1-9/0] Jump  [↑/↓] Navigate  [Enter] Confirm  [q/Esc] Cancel"

    _tui_read_key key
    case "$key" in
      CHAR:[1-9])
        local _t_num="${key#CHAR:}"
        local _t_idx=$(( _t_num - 1 ))
        if (( _t_idx < count )); then cursor=$_t_idx; fi
        ;;
      CHAR:0)
        if (( count >= 10 )); then cursor=9; fi
        ;;
      UP)
        if (( cursor > 0 )); then cursor=$((cursor - 1)); else cursor=$((count - 1)); fi
        ;;
      DOWN)
        if (( cursor < count - 1 )); then cursor=$((cursor + 1)); else cursor=0; fi
        ;;
      ENTER)
        break
        ;;
      QUIT|ESC)
        _tui_exit
        if declare -F handle_cancel >/dev/null 2>&1; then
          handle_cancel
        else
          return 130
        fi
        ;;
      REDRAW)
        continue
        ;;
    esac
  done

  _tui_exit
  printf -v "$selected_out" "%s" "$cursor"
  return 0
}

_tui_select_many() {
  local title="$1" subtitle="$2" state_ref="$3" has_toggle_all="$4"
  shift 4
  local labels=("$@")
  local count=${#labels[@]}
  local cursor=0 key idx i
  local -n sel="$state_ref"

  # Pre-flight check
  if ! _tui_is_interactive; then
    return 0
  fi

  _tui_enter

  while true; do
    _tui_clear
    _tui_update_dimensions
    _tui_draw_header "$title" "$subtitle"

    local max_w=$(( _TUI_COLS - 4 ))
    (( max_w > 80 )) && max_w=80
    (( max_w < 36 )) && max_w=36

    local all_mark=" "
    if (( has_toggle_all )); then
      local total_sel=0
      for ((i=1; i<count; i++)); do
        (( sel[i] )) && total_sel=$((total_sel + 1))
      done
      if (( total_sel == count - 1 )); then
        all_mark="*"
      elif (( total_sel > 0 )); then
        all_mark="-"
      fi
    fi

    for ((i=0; i<count; i++)); do
      local mark=" "
      if (( has_toggle_all && i == 0 )); then
        mark="$all_mark"
      else
        (( sel[i] )) && mark="x"
      fi

      local label_text=""
      _tui_truncate "${labels[i]}" "$((max_w - 10))" label_text
      if (( i == cursor )); then
        printf "  ${_TUI_GREEN}${_TUI_BOLD}> [%s] %s${_TUI_RESET}\n" "$mark" "$label_text" >/dev/tty
      else
        printf "    [%s] %s\n" "$mark" "$label_text" >/dev/tty
      fi
    done

    if (( has_toggle_all )); then
      _tui_draw_footer "[1-9/0] Jump  [↑/↓] Move  [Space] Toggle  [a] Toggle All  [Enter] Confirm  [q] Cancel"
    else
      _tui_draw_footer "[1-9/0] Jump  [↑/↓] Move  [Space] Toggle  [Enter] Confirm  [q] Cancel"
    fi

    _tui_read_key key
    case "$key" in
      CHAR:[1-9])
        local _t_num="${key#CHAR:}"
        local _t_idx=$(( _t_num - 1 ))
        if (( _t_idx < count )); then cursor=$_t_idx; fi
        ;;
      CHAR:0)
        if (( count >= 10 )); then cursor=9; fi
        ;;
      UP)
        if (( cursor > 0 )); then cursor=$((cursor - 1)); else cursor=$((count - 1)); fi
        ;;
      DOWN)
        if (( cursor < count - 1 )); then cursor=$((cursor + 1)); else cursor=0; fi
        ;;
      SPACE)
        if (( has_toggle_all && cursor == 0 )); then
          local all_on=1
          for ((idx=1; idx<count; idx++)); do
            (( sel[idx] == 0 )) && { all_on=0; break; }
          done
          for ((idx=1; idx<count; idx++)); do
            sel[idx]=$(( 1 - all_on ))
          done
        else
          sel[cursor]=$(( 1 - sel[cursor] ))
        fi
        ;;
      TOGGLE_ALL|ALL|CHAR:a|CHAR:A)
        if (( has_toggle_all )); then
          local all_on=1
          for ((idx=1; idx<count; idx++)); do
            (( sel[idx] == 0 )) && { all_on=0; break; }
          done
          for ((idx=1; idx<count; idx++)); do
            sel[idx]=$(( 1 - all_on ))
          done
        fi
        ;;
      ENTER)
        break
        ;;
      QUIT|ESC)
        _tui_exit
        if declare -F handle_cancel >/dev/null 2>&1; then
          handle_cancel
        else
          return 130
        fi
        ;;
      REDRAW)
        continue
        ;;
    esac
  done

  _tui_exit
  return 0
}
