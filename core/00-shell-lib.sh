# General shell helpers

portss() {
  ss -tulpn | grep "$1" | column -t
}

sudoportss() {
  sudo ss -tulpn | grep "$1" | column -t
}

# Graceful port termination (SIGTERM -> verify -> SIGKILL) with ss/lsof fallback
killport() {
  local port="${1:-}"
  local signal="${2:-15}"
  if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
    echo "Usage: killport <port_number> [signal]" >&2
    return 1
  fi

  local pids=""
  if command -v lsof >/dev/null 2>&1; then
    pids=$(lsof -t -n -P -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  elif command -v ss >/dev/null 2>&1; then
    pids=$(ss -lptn "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)
  fi

  if [[ -z "$pids" ]]; then
    echo "No listening process found on port $port."
    return 0
  fi

  echo "Terminating process(es) on port $port: $pids (signal: $signal)..."
  local pid
  for pid in $pids; do
    kill -"$signal" "$pid" 2>/dev/null || true
  done

  # Graceful check: escalate to SIGKILL if still active after brief pause
  sleep 0.2
  local remaining=""
  for pid in $pids; do
    if kill -0 "$pid" 2>/dev/null; then
      remaining="${remaining:+$remaining }$pid"
    fi
  done

  if [[ -n "$remaining" ]]; then
    echo "Escalating to SIGKILL (9) for PID(s): $remaining"
    for pid in $remaining; do
      kill -9 "$pid" 2>/dev/null || true
    done
  fi
  echo "✓ Port $port released."
}

# Path management helper (CWE-426 safe, trailing-slash clean, no duplicate or empty entries)
pathadd() {
  local dir="${1%/}"
  local pos="${2:-prepend}"
  [[ -d "$dir" ]] || return 0

  local new_path="" item clean_item
  local old_ifs="$IFS"
  IFS=":"
  for item in $PATH; do
    clean_item="${item%/}"
    if [[ "$clean_item" != "$dir" && -n "$clean_item" ]]; then
      new_path="${new_path:+$new_path:}$clean_item"
    fi
  done
  IFS="$old_ifs"

  if [[ -z "$new_path" ]]; then
    PATH="$dir"
  elif [[ "$pos" == "append" ]]; then
    PATH="$new_path:$dir"
  else
    PATH="$dir:$new_path"
  fi
  export PATH
}

# Create directory tree and navigate into target
mkcd() {
  if (($# == 0)); then
    echo "Usage: mkcd <directory>" >&2
    return 1
  fi
  local target="${!#}"
  mkdir -p -- "$@" && cd -- "$target"
}

# Create files and ensure parent directories exist
mktouch() {
  if (($# == 0)); then
    echo "Usage: mktouch <file> [file...]" >&2
    return 1
  fi
  local file parent
  for file in "$@"; do
    parent="$(dirname -- "$file")"
    [[ -d "$parent" ]] || mkdir -p -- "$parent"
    touch -- "$file"
  done
}

# Universal multi-archive extractor
extract() {
  if (($# == 0)); then
    echo "Usage: extract <archive> [archive...]" >&2
    return 1
  fi
  local file
  for file in "$@"; do
    if [[ ! -f "$file" ]]; then
      echo "extract: '$file' is not a valid file" >&2
      continue
    fi
    case "${file,,}" in
      *.tar.gz|*.tgz)    tar -xzf "$file" ;;
      *.tar.bz2|*.tbz2)  tar -xjf "$file" ;;
      *.tar.xz|*.txz)    tar -xJf "$file" ;;
      *.tar.zst)         tar --zstd -xf "$file" ;;
      *.tar)             tar -xf "$file" ;;
      *.zip)             unzip -q "$file" ;;
      *.rar)             unrar x "$file" ;;
      *.7z)              7z x "$file" ;;
      *.gz)              gunzip "$file" ;;
      *.bz2)             bunzip2 "$file" ;;
      *.xz)              unxz "$file" ;;
      *)
        echo "extract: unsupported archive format: '$file'" >&2
        ;;
    esac
  done
}

lsfunc() {
  if (($# == 0)); then
    echo "Available functions:"
    declare -F |
      awk '{print $3}' |
      sort |
      grep -v '^_' |
      awk '{printf "%2d. %s\n", NR, $0}'
    return
  fi

  if declare -F "$1" &>/dev/null; then
    type "$1" | tail -n +2
  else
    echo "Function '$1' not found"
    return 1
  fi
}


# Common shell helpers

# Dynamic ZenCLI State Directory & Command Log
_ZEN_STATE_DIR="${ZENCLI_STATE_DIR:-${ZEN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zencli}}"
_CMD_LOG="${_CMD_LOG:-${CMD_LOG:-$_ZEN_STATE_DIR/commands.log}}"

# Auto-migrate legacy ~/.local/state/dotfiles and ~/.local/state/zen if present
for _legacy_dir in "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles" "${XDG_STATE_HOME:-$HOME/.local/state}/zen"; do
  if [[ -d "$_legacy_dir" && "$_legacy_dir" != "$_ZEN_STATE_DIR" ]]; then
    mkdir -p "$_ZEN_STATE_DIR" 2>/dev/null || true
    if [[ -f "$_legacy_dir/commands.log" && ! -f "$_CMD_LOG" ]]; then
      mv "$_legacy_dir/commands.log" "$_CMD_LOG" 2>/dev/null || true
    elif [[ -f "$_legacy_dir/commands.log" && -f "$_CMD_LOG" ]]; then
      cat "$_legacy_dir/commands.log" >> "$_CMD_LOG" 2>/dev/null || true
      rm -f "$_legacy_dir/commands.log" 2>/dev/null || true
    fi
    rm -rf "$_legacy_dir" 2>/dev/null || true
  fi
done

# Separate consecutive prompt blocks without polluting captured stdout.
_prompt_gap() {
  printf '\n' >&2
}

_confirm() {
  local prompt="${1:-OK? [Y/n] }"
  local a default="y"
  [[ $prompt =~ \[y/N\] ]] && default="n"
  _prompt_gap
  read -rp "$prompt" a
  [[ ${a:-$default} =~ ^[Yy]$ ]]
}

_format_cmdline() {
  if (($# == 1)) && [[ "$1" =~ [[:space:]] ]]; then
    printf '%s' "$1"
    return
  fi

  local arg out=""
  for arg in "$@"; do
    if [[ -z $arg ]]; then
      out+="${out:+ }''"
    elif [[ "$arg" == *" "* || "$arg" == *$'\t'* || "$arg" == *$'\n'* || "$arg" == *"'"* ]]; then
      local quoted="'${arg//\'/\'\\\'\'}'"
      out+="${out:+ }$quoted"
    else
      local q
      printf -v q '%q' "$arg"
      out+="${out:+ }$q"
    fi
  done
  printf '%s' "$out"
}

_log_cmd_record() {
  local status="$1" duration="$2" cwd="$3"
  shift 3
  mkdir -p "$(dirname "$_CMD_LOG")"

  local cmd_str
  cmd_str="$(_format_cmdline "$@")"

  {
    printf '[%s] [status:%s] [dur:%ss] [cwd:%s] ▶ %s\n' \
      "$(date '+%F %T')" "$status" "$duration" "$cwd" "$cmd_str"
  } >>"$_CMD_LOG"
}

_log_cmd() {
  local cwd="${PWD:-$HOME}"
  _log_cmd_record "0" "0" "$cwd" "$@"
}

# Print the label/icon and the command on separate lines so the command can be
# selected and copied without picking up the prefix.
_print_cmdline() {
  _format_cmdline "$@"
  printf '\n'
}

_print_cmd() {
  local label="$1"
  shift

  printf '▶ %s\n' "$label"
  _print_cmdline "$@"
}

_run_confirm() {
  printf '\n'
  _print_cmd "Command:" "$@"

  _confirm || {
    echo "✗ cancelled"
    return 1
  }

  local start_time=$SECONDS
  local cwd="${PWD:-$HOME}"
  local rc=0

  "$@" || rc=$?

  local duration=$((SECONDS - start_time))
  _log_cmd_record "$rc" "$duration" "$cwd" "$@"

  return $rc
}

_pick_one() {
  local PS3="$1" item
  shift

  (($#)) || return 1
  (($# == 1)) && { echo "$1"; return; }

  _prompt_gap
  select item in "$@"; do
    [[ -n $item ]] && { echo "$item"; return; }
  done
}

_pick_many() {
  local title="$1" picked n ok=0
  shift
  local items=("$@")

  ((${#items[@]})) || return 1
  ((${#items[@]} == 1)) && { echo "${items[0]}"; return; }

  _prompt_gap
  echo "$title" >&2
  for n in "${!items[@]}"; do
    printf '  %d) %s\n' "$((n+1))" "${items[n]}" >&2
  done

  read -rp "#? (space-sep): " -a picked

  for n in "${picked[@]}"; do
    [[ $n =~ ^[0-9]+$ ]] &&
      ((n >= 1 && n <= ${#items[@]})) &&
      { echo "${items[n-1]}"; ok=1; }
  done

  ((ok))
}
