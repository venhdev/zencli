# Confirmed command audit log manager & rerun helpers

_cmdlog_get_path() {
  if declare -F _get_cmdlog_path >/dev/null 2>&1; then
    _get_cmdlog_path
  else
    local state_dir="${ZENCLI_STATE_DIR:-${ZEN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zencli}}"
    echo "${_CMD_LOG:-${CMD_LOG:-$state_dir/commands.log}}"
  fi
}

_cmdlog_file() {
  _cmdlog_get_path "$@"
}

_cmdlog_parse_records() {
  local file="$1"
  [[ -f $file ]] || return 0

  local reverse_cmd="tac"
  command -v tac &>/dev/null || reverse_cmd="awk '{a[i++]=\$0} END {for (j=i-1; j>=0; j--) print a[j]}'"

  eval "$reverse_cmd" "$file" | while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\](.*)$ ]]; then
      local ts="${BASH_REMATCH[1]}"
      local rest="${BASH_REMATCH[2]}"
      local status="-" dur="-" cwd="-" cmd=""

      if [[ $rest =~ \[status:([^]]*)\] ]]; then status="${BASH_REMATCH[1]}"; fi
      if [[ $rest =~ \[dur:([^]]*)\] ]]; then dur="${BASH_REMATCH[1]}"; fi
      if [[ $rest =~ \[cwd:([^]]*)\] ]]; then cwd="${BASH_REMATCH[1]}"; fi

      if [[ $rest == *" ▶ "* ]]; then
        cmd="${rest#* ▶ }"
      else
        cmd="${rest# }"
        cmd="${cmd//\\ / }"
      fi

      # Trim whitespace
      cmd="${cmd%"${cmd##*[![:space:]]}"}"
      cmd="${cmd#"${cmd%%[![:space:]]*}"}"

      [[ -n $cmd ]] || continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$status" "$dur" "$cwd" "$cmd"
    fi
  done
}

_cmdlog_shorten_path() {
  local p="$1"
  local out_var="${2:-}"
  local res="$p"
  if [[ $p == "$HOME"* ]]; then
    res="~${p#"$HOME"}"
  fi
  if [[ -n "$out_var" ]]; then
    printf -v "$out_var" "%s" "$res"
  else
    printf "%s\n" "$res"
  fi
}

_cmdlog_help() {
  cat <<'EOF'
cmdlog / clog - Confirmed Command Audit Log & Rerun

Usage:
  clog [query] [limit]    View recent confirmed commands (default: 10)
  clog -d [limit]         View commands executed in current directory ($PWD)
  clog -a / all           View full command history
  clog path               Print path to commands.log
  clog clean [--keep N]   Truncate log keeping latest N entries (default: 500)
  clog clip [index]       Copy command to clipboard (default: latest)

  cr [query|index]        Interactive picker or direct rerun by index
  cr -f [query]           Use fzf fuzzy finder if preferred
  cr -e [index]           Edit command before rerun (Readline prompt)
  cr -d [query]           Rerun scoped to current directory ($PWD)

Aliases:
  clog -> cmdlog
  cr   -> cmdlog run
EOF
}

_cmdlog_clean() {
  local file="$1"
  shift
  local keep=500

  while (($# > 0)); do
    case "$1" in
      --keep|-k)
        keep="$2"
        shift 2
        ;;
      [0-9]*)
        keep="$1"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  [[ -f $file ]] || {
    echo "Log file not found: $file" >&2
    return 1
  }

  local total
  total=$(wc -l < "$file")
  if ((total <= keep)); then
    echo "Log has $total entries (<= $keep). No truncation needed."
    return 0
  fi

  local tmp_file tmp_dir
  if declare -F _get_zen_tmp_dir >/dev/null 2>&1; then
    tmp_dir="$(_get_zen_tmp_dir)"
  else
    tmp_dir="${TMPDIR:-/tmp}/zencli"
    [[ -d "$tmp_dir" ]] || mkdir -p "$tmp_dir" 2>/dev/null || true
  fi
  tmp_file="$(mktemp "${tmp_dir}/cmdlog.XXXXXX")"
  tail -n "$keep" "$file" > "$tmp_file" && mv "$tmp_file" "$file"
  echo "Cleaned log: kept latest $keep entries (was $total)."
}

_cmdlog_clip() {
  local file="$1"
  shift
  local target_idx="${1:-1}"
  [[ $target_idx =~ ^[0-9]+$ ]] || target_idx=1

  local line cmd
  line=$(_cmdlog_parse_records "$file" | sed -n "${target_idx}{p;q}")
  [[ -n $line ]] || {
    echo "No log entry found at index $target_idx" >&2
    return 1
  }

  IFS=$'\t' read -r _ _ _ _ cmd <<< "$line"
  _cmdlog_copy_to_clip "$cmd"
}

_cmdlog_list() {
  local file="$1"
  shift

  local limit=10
  local query=""
  local cwd_only=0
  local show_all=0

  while (($# > 0)); do
    case "$1" in
      -d|--cwd|\.)
        cwd_only=1
        shift
        ;;
      -a|--all|all)
        show_all=1
        shift
        ;;
      [0-9]*)
        limit="$1"
        shift
        ;;
      *)
        query="${query:+$query }$1"
        shift
        ;;
    esac
  done

  ((show_all)) && limit=999999
  ((limit <= 0)) && limit=10

  local entries=()
  local seen_cmds=$'\n'
  local ts status dur cwd cmd
  local current_pwd="${PWD:-$HOME}"

  while IFS=$'\t' read -r ts status dur cwd cmd || [[ -n $cmd ]]; do
    [[ -n $ts ]] || continue

    if ((cwd_only)) && [[ $cwd != "$current_pwd" ]]; then
      continue
    fi

    if [[ -n $query ]]; then
      local lower_cmd="${cmd,,}"
      local lower_query="${query,,}"
      if [[ $lower_cmd != *"$lower_query"* && ${cwd,,} != *"$lower_query"* ]]; then
        continue
      fi
    fi

    # Deduplication: keep only the latest occurrence
    if [[ $seen_cmds == *$'\n'"$cmd"$'\n'* ]]; then
      continue
    fi
    seen_cmds+="$cmd"$'\n'

    entries+=("$ts"$'\t'"$status"$'\t'"$dur"$'\t'"$cwd"$'\t'"$cmd")
    ((${#entries[@]} >= limit)) && break
  done < <(_cmdlog_parse_records "$file")

  local total=${#entries[@]}
  if ((total == 0)); then
    if ((cwd_only)); then
      echo "No confirmed commands found for current directory ($current_pwd)" >&2
    elif [[ -n $query ]]; then
      echo "No confirmed commands matching '$query'" >&2
    else
      echo "No confirmed commands found in log." >&2
    fi
    return 0
  fi

  local title="Confirmed Commands (latest $total)"
  ((cwd_only)) && title="Confirmed Commands in $current_pwd (latest $total)"
  [[ -n $query ]] && title="Confirmed Commands matching '$query' (latest $total)"

  printf '\033[1;34m=== %s ===\033[0m\n' "$title"

  local max_cols
  max_cols=$(tput cols 2>/dev/null || echo "${COLUMNS:-80}")
  ((max_cols <= 20)) && max_cols=80

  local i
  for i in "${!entries[@]}"; do
    IFS=$'\t' read -r ts status dur cwd cmd <<< "${entries[i]}"
    local idx=$((i + 1))
    local st_str=""
    case "$status" in
      0)   st_str="\033[1;32m[OK]\033[0m" ;;
      "-") st_str="\033[0;90m[-]\033[0m" ;;
      *)   st_str="\033[1;31m[ERR:$status]\033[0m" ;;
    esac

    local cwd_str=""
    if [[ $cwd != "-" && -n $cwd ]]; then
      local short_cwd=""
      _cmdlog_shorten_path "$cwd" short_cwd
      cwd_str=" \033[0;33m[$short_cwd]\033[0m"
    fi

    local disp_cmd="$cmd"
    if (( ${#disp_cmd} > max_cols - 2 )); then
      disp_cmd="${disp_cmd:0:$((max_cols - 5))}..."
    fi

    if ((i < total - 1)); then
      printf ' \033[1;36m[%d]\033[0m \033[0;90m%s\033[0m %b%b\n%s\n\n' \
        "$idx" "$ts" "$st_str" "$cwd_str" "$disp_cmd"
    else
      printf ' \033[1;36m[%d]\033[0m \033[0;90m%s\033[0m %b%b\n%s\n' \
        "$idx" "$ts" "$st_str" "$cwd_str" "$disp_cmd"
    fi
  done
}

_cmdlog_copy_to_clip() {
  local to_copy="$1"
  if declare -F clip >/dev/null 2>&1; then
    printf '%s' "$to_copy" | clip
  elif command -v clip.exe >/dev/null 2>&1; then
    printf '%s' "$to_copy" | clip.exe
  elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$to_copy" | wl-copy
  elif command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$to_copy" | pbcopy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$to_copy" | xclip -selection clipboard
  fi
  # Emit OSC 52 clipboard escape sequence for terminal / SSH / tmux integration
  if command -v base64 >/dev/null 2>&1; then
    local b64
    b64=$(printf '%s' "$to_copy" | base64 | tr -d '\r\n')
    printf '\033]52;c;%s\a' "$b64" >/dev/tty 2>/dev/null || true
  fi
  echo "✓ Copied to clipboard: $to_copy"
}

_cmdlog_tui_cleanup() {
  tput cnorm >/dev/tty 2>/dev/null || printf "\033[?25h" >/dev/tty
}

_cmdlog_tui_apply_filter() {
  local query="${1,,}"
  local -n _raw_list="$2"
  local -n _out_indices="$3"
  local -n _cursor_ref="$4"
  local total=${#_raw_list[@]}
  local i
  _out_indices=()
  for ((i=0; i<total; i++)); do
    local r_entry="${_raw_list[i]}"
    local e_cmd="${r_entry#*$'\t'*$'\t'*$'\t'*$'\t'}"
    local item_lower="${e_cmd,,}"
    if [[ -z "$query" || "$item_lower" == *"$query"* ]]; then
      _out_indices+=("$i")
    fi
  done
  if ((_cursor_ref >= ${#_out_indices[@]})); then
    _cursor_ref=$(( ${#_out_indices[@]} > 0 ? ${#_out_indices[@]} - 1 : 0 ))
  fi
}

_cmdlog_tui_render_view() {
  local prompt_title="$1"
  local search_mode="$2"
  local filter_query="$3"
  local cursor="$4"
  local max_cols="$5"
  local -n _v_raw="$6"
  local -n _v_indices="$7"

  printf "\033[H\033[2J" >/dev/tty
  printf "\033[1;34m=== %s ===\033[0m\n" "$prompt_title" >/dev/tty
  if ((search_mode)); then
    printf "\033[1;33m[SEARCH]\033[0m Query: \033[1m%s\033[0m█ \033[90m(Enter/Esc: Done searching | ↑/↓: Select | Tab: Copy)\033[0m\n" "$filter_query" >/dev/tty
  else
    if [[ -n "$filter_query" ]]; then
      printf "\033[90m[1-9/0] Jump | [↑/↓/j/k] Move | [/] Search | [c] Copy | [r/Enter] Run | [Esc] Clear filter | [q] Cancel\033[0m\n" >/dev/tty
      printf "\033[0;33mFiltered by:\033[0m '%s' \033[90m(press / to edit, Esc to clear)\033[0m\n" "$filter_query" >/dev/tty
    else
      printf "\033[90m[1-9/0] Jump | [↑/↓/j/k] Move | [/] Search | [c] Copy | [r/Enter] Run | [q] Cancel\033[0m\n" >/dev/tty
    fi
  fi
  printf "\n" >/dev/tty

  local f_count=${#_v_indices[@]}
  if ((f_count == 0)); then
    printf " \033[90m(No commands match '%s')\033[0m\n\n" "$filter_query" >/dev/tty
    return 0
  fi

  local idx
  for ((idx=0; idx<f_count; idx++)); do
    local orig_i="${_v_indices[idx]}"
    local entry="${_v_raw[orig_i]}"
    local ts status dur cwd cmd
    IFS=$'\t' read -r ts status dur cwd cmd <<< "$entry"

    local st_str=""
    case "$status" in
      0)   st_str="\033[1;32m[OK]\033[0m" ;;
      "-") st_str="\033[0;90m[-]\033[0m" ;;
      *)   st_str="\033[1;31m[ERR:$status]\033[0m" ;;
    esac

    local cwd_str=""
    if [[ $cwd != "-" && -n $cwd ]]; then
      local short_cwd=""
      _cmdlog_shorten_path "$cwd" short_cwd
      cwd_str=" \033[0;33m[$short_cwd]\033[0m"
    fi

    local disp_cmd="$cmd"
    if (( ${#disp_cmd} > max_cols - 2 )); then
      disp_cmd="${disp_cmd:0:$((max_cols - 5))}..."
    fi

    if ((idx == cursor)); then
      printf "\033[1;32m▶ [%d]\033[0m \033[0;90m%s\033[0m %b%b\n\033[1m%s\033[0m\n\n" \
        "$((orig_i + 1))" "$ts" "$st_str" "$cwd_str" "$disp_cmd" >/dev/tty
    else
      printf "  \033[1;36m[%d]\033[0m \033[0;90m%s\033[0m %b%b\n%s\n\n" \
        "$((orig_i + 1))" "$ts" "$st_str" "$cwd_str" "$disp_cmd" >/dev/tty
    fi
  done
}

_cmdlog_tui_handle_search() {
  local key="$1"
  local -n _s_raw="$2"
  local -n _s_indices="$3"
  local -n _s_cursor="$4"
  local -n _s_query="$5"
  local -n _s_mode="$6"
  local -n _s_act="$7"
  local -n _s_idx="$8"

  local f_count=${#_s_indices[@]}

  if [[ $key == $'\x1b' ]]; then
    local seq=""
    read -rsn2 -t 0.02 seq < /dev/tty || true
    case "$seq" in
      "[A"|"OA") ((_s_cursor > 0)) && _s_cursor=$((_s_cursor - 1)) ;;
      "[B"|"OB") ((_s_cursor < f_count - 1)) && _s_cursor=$((_s_cursor + 1)) ;;
      "") _s_mode=0 ;; # Plain Esc exits search mode to navigation mode, keeping filter_query
    esac
  elif [[ $key == "" || $key == $'\n' || $key == $'\r' ]]; then
    # Enter exits search mode to navigation mode, keeping filter_query
    _s_mode=0
  elif [[ $key == $'\t' ]]; then
    if ((f_count > 0)); then
      _s_act="COPY"
      _s_idx="${_s_indices[_s_cursor]}"
      return 1
    fi
  elif [[ $key == $'\x7f' || $key == $'\b' ]]; then
    if [[ -n "$_s_query" ]]; then
      _s_query="${_s_query:0:-1}"
      _cmdlog_tui_apply_filter "$_s_query" _s_raw _s_indices _s_cursor
    fi
  else
    if [[ $key =~ [[:print:]] ]]; then
      _s_query+="$key"
      _cmdlog_tui_apply_filter "$_s_query" _s_raw _s_indices _s_cursor
    fi
  fi
  return 0
}

_cmdlog_tui_handle_nav() {
  local key="$1"
  local total="$2"
  local -n _n_raw="$3"
  local -n _n_indices="$4"
  local -n _n_cursor="$5"
  local -n _n_query="$6"
  local -n _n_mode="$7"
  local -n _n_act="$8"
  local -n _n_idx="$9"

  local f_count=${#_n_indices[@]}

  if [[ $key == $'\x1b' ]]; then
    local seq=""
    read -rsn2 -t 0.02 seq < /dev/tty || true
    case "$seq" in
      "[A"|"OA") ((_n_cursor > 0)) && _n_cursor=$((_n_cursor - 1)) ;;
      "[B"|"OB") ((_n_cursor < f_count - 1)) && _n_cursor=$((_n_cursor + 1)) ;;
      "")
        if [[ -n "$_n_query" ]]; then
          _n_query=""
          _cmdlog_tui_apply_filter "$_n_query" _n_raw _n_indices _n_cursor
        else
          _n_act="CANCEL"
          return 1
        fi
        ;;
    esac
  elif [[ $key =~ ^[1-9]$ ]]; then
    local target_orig=$((key - 1))
    local f_idx
    for ((f_idx=0; f_idx<f_count; f_idx++)); do
      if ((_n_indices[f_idx] == target_orig)); then
        _n_cursor=$f_idx
        break
      fi
    done
  elif [[ $key == "0" ]] && ((total >= 10)); then
    local target_orig=9
    local f_idx
    for ((f_idx=0; f_idx<f_count; f_idx++)); do
      if ((_n_indices[f_idx] == target_orig)); then
        _n_cursor=$f_idx
        break
      fi
    done
  elif [[ $key == "k" || $key == "K" ]]; then
    ((_n_cursor > 0)) && _n_cursor=$((_n_cursor - 1))
  elif [[ $key == "j" || $key == "J" ]]; then
    ((_n_cursor < f_count - 1)) && _n_cursor=$((_n_cursor + 1))
  elif [[ $key == "/" ]]; then
    _n_mode=1
  elif [[ $key == "q" || $key == "Q" || $key == $'\x03' ]]; then
    _n_act="CANCEL"
    return 1
  elif [[ $key == "c" || $key == "C" ]]; then
    if ((f_count > 0)); then
      _n_act="COPY"
      _n_idx="${_n_indices[_n_cursor]}"
      return 1
    fi
  elif [[ $key == "r" || $key == "R" || $key == "" || $key == $'\n' || $key == $'\r' ]]; then
    if ((f_count > 0)); then
      _n_act="RUN"
      _n_idx="${_n_indices[_n_cursor]}"
      return 1
    fi
  fi
  return 0
}

_cmdlog_tui_select() {
  local prompt_title="$1"
  local -n _sel_action="$2"
  local -n _sel_idx="$3"
  shift 3
  local raw_entries=("$@")
  local total=${#raw_entries[@]}
  ((total == 0)) && return 1

  _sel_action="CANCEL"
  _sel_idx=""

  local cursor=0
  local search_mode=0
  local filter_query=""
  local filtered_indices=()
  local i

  for ((i=0; i<total; i++)); do filtered_indices+=("$i"); done

  local max_cols
  max_cols=$(tput cols 2>/dev/null || echo "${COLUMNS:-80}")
  ((max_cols <= 20)) && max_cols=80

  # Hide cursor on TTY
  tput civis >/dev/tty 2>/dev/null || printf "\033[?25l" >/dev/tty
  trap _cmdlog_tui_cleanup RETURN INT TERM

  while true; do
    _cmdlog_tui_render_view "$prompt_title" "$search_mode" "$filter_query" "$cursor" "$max_cols" raw_entries filtered_indices

    # Read keystroke
    local key=""
    IFS= read -rsn1 key < /dev/tty

    if ((search_mode)); then
      _cmdlog_tui_handle_search "$key" raw_entries filtered_indices cursor filter_query search_mode _sel_action _sel_idx || return 0
    else
      _cmdlog_tui_handle_nav "$key" "$total" raw_entries filtered_indices cursor filter_query search_mode _sel_action _sel_idx || return 0
    fi
  done
}

_cmdlog_collect_entries() {
  local file="$1"
  local cwd_only="$2"
  local query="$3"
  local limit="$4"
  local -n _out_entries="$5"

  local seen_cmds=$'\n'
  local ts status dur cwd cmd
  local current_pwd="${PWD:-$HOME}"

  _out_entries=()
  while IFS=$'\t' read -r ts status dur cwd cmd || [[ -n $cmd ]]; do
    [[ -n $ts ]] || continue

    if ((cwd_only)) && [[ $cwd != "$current_pwd" ]]; then
      continue
    fi

    if [[ -n $query ]]; then
      local lower_cmd="${cmd,,}"
      local lower_query="${query,,}"
      if [[ $lower_cmd != *"$lower_query"* && ${cwd,,} != *"$lower_query"* ]]; then
        continue
      fi
    fi

    # Deduplication: keep only the latest occurrence
    if [[ $seen_cmds == *$'\n'"$cmd"$'\n'* ]]; then
      continue
    fi
    seen_cmds+="$cmd"$'\n'

    _out_entries+=("$ts"$'\t'"$status"$'\t'"$dur"$'\t'"$cwd"$'\t'"$cmd")
    ((${#_out_entries[@]} >= limit)) && break
  done < <(_cmdlog_parse_records "$file")
}

_cmdlog_fzf_select() {
  local query="$1"
  local -n _fzf_entries="$2"
  local -n _chosen_out="$3"

  local fzf_input="" i
  for i in "${!_fzf_entries[@]}"; do
    local ts status dur cwd cmd
    IFS=$'\t' read -r ts status dur cwd cmd <<< "${_fzf_entries[i]}"
    local short_cwd=""
    _cmdlog_shorten_path "$cwd" short_cwd
    local st_color=""
    case "$status" in
      0)   st_color=$'\033[1;32m[OK]\033[0m' ;;
      "-") st_color=$'\033[0;90m[-]\033[0m' ;;
      *)   st_color=$'\033[1;31m[ERR:'"$status"']\033[0m' ;;
    esac
    fzf_input+="$((i + 1))"$'\t'"$ts"$'\t'"$st_color"$'\t'"[$short_cwd]"$'\t'"$cmd"$'\n'
  done

  local fzf_res
  fzf_res=$(printf '%s' "$fzf_input" | fzf \
    --ansi \
    --height 50% \
    --reverse \
    --delimiter=$'\t' \
    --with-nth 1,2,3,4,5 \
    --preview 'echo -e "\033[1;36mCommand:\033[0m\n{5}"' \
    --preview-window=down:3:wrap \
    --prompt="Rerun > " \
    --header="[Enter] Run | [Ctrl-Y/Alt-C] Copy | [Esc] Cancel" \
    --expect=enter,ctrl-y,alt-c \
    --query="$query" || true)

  local fzf_key chosen_line
  fzf_key=$(echo "$fzf_res" | head -n 1)
  chosen_line=$(echo "$fzf_res" | sed 1d)

  if [[ -z "$chosen_line" ]]; then
    echo "Cancelled"
    return 1
  fi

  local chosen_num
  chosen_num=$(echo "$chosen_line" | cut -f1)
  local selected_entry="${_fzf_entries[chosen_num - 1]}"
  local s_ts s_st s_dur s_cwd s_cmd
  IFS=$'\t' read -r s_ts s_st s_dur s_cwd s_cmd <<< "$selected_entry"

  if [[ "$fzf_key" == "ctrl-y" || "$fzf_key" == "alt-c" ]]; then
    _cmdlog_copy_to_clip "$s_cmd"
    return 2
  fi

  _chosen_out="$chosen_num"
  return 0
}

_cmdlog_fallback_select() {
  local title="$1"
  local -n _fb_entries="$2"
  local -n _chosen_out="$3"
  local total=${#_fb_entries[@]}

  printf '\033[1;34m=== %s ===\033[0m\n' "$title"
  local i
  for i in "${!_fb_entries[@]}"; do
    local ts status dur cwd cmd
    IFS=$'\t' read -r ts status dur cwd cmd <<< "${_fb_entries[i]}"
    local st_str=""
    case "$status" in
      0)   st_str="\033[1;32m[OK]\033[0m" ;;
      "-") st_str="\033[0;90m[-]\033[0m" ;;
      *)   st_str="\033[1;31m[ERR:$status]\033[0m" ;;
    esac
    local cwd_str=""
    if [[ $cwd != "-" && -n $cwd ]]; then
      local short_cwd=""
      _cmdlog_shorten_path "$cwd" short_cwd
      cwd_str=" \033[0;33m[$short_cwd]\033[0m"
    fi
    if ((i < total - 1)); then
      printf ' \033[1;36m[%d]\033[0m \033[0;90m%s\033[0m %b%b\n%s\n\n' \
        "$((i + 1))" "$ts" "$st_str" "$cwd_str" "$cmd"
    else
      printf ' \033[1;36m[%d]\033[0m \033[0;90m%s\033[0m %b%b\n%s\n' \
        "$((i + 1))" "$ts" "$st_str" "$cwd_str" "$cmd"
    fi
  done

  local choice
  if ! read -rp "Select [1-$total, default 1, c <num> to copy, q to cancel]: " choice; then
    echo "Cancelled"
    return 1
  fi

  case "$choice" in
    q|Q|0)
      echo "Cancelled"
      return 1
      ;;
    c*|clip*|copy*)
      local copy_idx="${choice#* }"
      [[ "$copy_idx" =~ ^[0-9]+$ ]] || copy_idx=1
      if ((copy_idx >= 1 && copy_idx <= total)); then
        local to_copy="${_fb_entries[copy_idx - 1]}"
        local c_ts c_st c_dur c_cwd c_cmd
        IFS=$'\t' read -r c_ts c_st c_dur c_cwd c_cmd <<< "$to_copy"
        _cmdlog_copy_to_clip "$c_cmd"
        return 2
      else
        echo "Invalid copy index: $copy_idx (must be 1-$total)" >&2
        return 1
      fi
      ;;
    "")
      _chosen_out=1
      ;;
    *)
      _chosen_out="$choice"
      ;;
  esac
  return 0
}

_cmdlog_dispatch_execution() {
  local cmd="$1"
  local orig_cwd="$2"
  local current_pwd="$3"
  local interactive_choice="$4"
  local edit_mode="$5"

  # CWD difference check
  if [[ $orig_cwd != "-" && -n $orig_cwd && $orig_cwd != "$current_pwd" && -d $orig_cwd ]]; then
    printf '\033[1;33m⚠️  CWD Notice:\033[0m Command originally ran in:\n' >&2
    printf '   Original: %s\n' "$orig_cwd" >&2
    printf '   Current:  %s\n' "$current_pwd" >&2
    local dir_choice
    read -rp "Run in current dir [y], cd to original dir and run [c], cancel [N]? " dir_choice
    case "$dir_choice" in
      c|C)
        echo "Navigating to: $orig_cwd"
        cd "$orig_cwd" || return 1
        ;;
      y|Y)
        ;;
      *)
        echo "Cancelled"
        return 0
        ;;
    esac
  fi

  local cmd_to_run="$cmd"

  if ((edit_mode)); then
    read -e -i "$cmd_to_run" -p "Edit command: " edited_cmd
    [[ -n $edited_cmd ]] || { echo "Cancelled"; return 0; }
    cmd_to_run="$edited_cmd"
  fi

  if ((interactive_choice)); then
    printf '\n\033[1;36m▶ Run:\033[0m %s\n' "$cmd_to_run"
    if ! _confirm "Execute command? [Y/n] "; then
      echo "Cancelled"
      return 0
    fi
  else
    printf '\n▶ %s\n' "$cmd_to_run"
  fi
  history -s "$cmd_to_run" 2>/dev/null || true

  local start_time=$SECONDS
  local run_cwd="${PWD:-$HOME}"
  local rc=0

  eval "$cmd_to_run" || rc=$?

  local duration=$((SECONDS - start_time))
  if declare -F _log_cmd_record &>/dev/null; then
    _log_cmd_record "$rc" "$duration" "$run_cwd" "$cmd_to_run"
  fi

  return $rc
}

_cmdlog_run() {
  local file="$1"
  shift

  local limit=10
  local query=""
  local cwd_only=0
  local edit_mode=0
  local use_fzf=0
  local target_idx=""

  [[ -n "${DOTFILES_CR_FZF:-}" ]] && use_fzf=1

  while (($# > 0)); do
    case "$1" in
      -f|--fzf)
        use_fzf=1
        shift
        ;;
      --no-fzf)
        use_fzf=0
        shift
        ;;
      -e|--edit)
        edit_mode=1
        shift
        ;;
      -d|--cwd|\.)
        cwd_only=1
        shift
        ;;
      *)
        if [[ "$1" =~ ^[0-9]+$ ]] && [[ -z $target_idx ]]; then
          target_idx="$1"
        else
          query="${query:+$query }$1"
        fi
        shift
        ;;
    esac
  done

  local entries=()
  _cmdlog_collect_entries "$file" "$cwd_only" "$query" "$limit" entries

  local total=${#entries[@]}
  if ((total == 0)); then
    echo "No matching commands found to run." >&2
    return 1
  fi

  local chosen_idx="$target_idx"
  local interactive_choice=0

  if [[ -z $chosen_idx ]]; then
    local title="Rerun Confirmed Commands (latest $total)"
    [[ -n $query ]] && title="Rerun Commands matching '$query' (latest $total)"

    if [[ -t 0 && -t 1 ]] && [[ -e /dev/tty ]]; then
      if ((use_fzf)) && command -v fzf >/dev/null 2>&1; then
        _cmdlog_fzf_select "$query" entries chosen_idx
        local fzf_status=$?
        if ((fzf_status == 1 || fzf_status == 2)); then return 0; fi
        interactive_choice=1
      else
        local tui_action="CANCEL" tui_chosen_idx=""
        _cmdlog_tui_select "$title" tui_action tui_chosen_idx "${entries[@]}"
        case "$tui_action" in
          COPY)
            local to_copy="${entries[tui_chosen_idx]}"
            local c_ts c_st c_dur c_cwd c_cmd
            IFS=$'\t' read -r c_ts c_st c_dur c_cwd c_cmd <<< "$to_copy"
            _cmdlog_copy_to_clip "$c_cmd"
            return 0
            ;;
          RUN)
            chosen_idx=$((tui_chosen_idx + 1))
            interactive_choice=1
            ;;
          *)
            echo "Cancelled"
            return 0
            ;;
        esac
      fi
    else
      _cmdlog_fallback_select "$title" entries chosen_idx
      local fb_status=$?
      if ((fb_status != 0)); then return 0; fi
    fi
  fi

  if ! [[ "$chosen_idx" =~ ^[0-9]+$ ]] || ((chosen_idx < 1 || chosen_idx > total)); then
    echo "Invalid selection: $chosen_idx (must be 1-$total)" >&2
    return 1
  fi

  local selected_entry="${entries[chosen_idx - 1]}"
  local ts status dur cwd cmd
  IFS=$'\t' read -r ts status dur cwd cmd <<< "$selected_entry"

  _cmdlog_dispatch_execution "$cmd" "$cwd" "${PWD:-$HOME}" "$interactive_choice" "$edit_mode"
}

cmdlog() {
  local log_file
  log_file="$(_cmdlog_get_path)"

  case "${1:-}" in
    path)
      echo "$log_file"
      return 0
      ;;
    help|--help|-h)
      _cmdlog_help
      return 0
      ;;
    clean)
      shift
      _cmdlog_clean "$log_file" "$@"
      return $?
      ;;
    clip|cp)
      shift
      _cmdlog_clip "$log_file" "$@"
      return $?
      ;;
    run)
      shift
      _cmdlog_run "$log_file" "$@"
      return $?
      ;;
    *)
      _cmdlog_list "$log_file" "$@"
      return $?
      ;;
  esac
}

# Clean up any preexisting aliases from earlier sessions or dotfiles loads
unalias clog cr 2>/dev/null || true

# Provide wrapper functions so clog and cr work across interactive shells
# and subshells without alias collision or re-source errors.
clog() {
  cmdlog "$@"
}

cr() {
  cmdlog run "$@"
}
