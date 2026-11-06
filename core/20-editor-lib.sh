# Editor helpers

if [[ -n ${DOTFILES_EDITOR:-} ]] && command -v "$DOTFILES_EDITOR" &>/dev/null; then
  export EDITOR="$DOTFILES_EDITOR"
elif [[ -n ${EDITOR:-} ]] && command -v "$EDITOR" &>/dev/null; then
  export EDITOR="$EDITOR"
elif command -v micro &>/dev/null; then
  export EDITOR=micro
elif command -v nvim &>/dev/null; then
  export EDITOR=nvim
elif command -v nano &>/dev/null; then
  export EDITOR=nano
elif command -v vim &>/dev/null; then
  export EDITOR=vim
else
  export EDITOR=vi
fi

export VISUAL="$EDITOR"

e() {
  "$EDITOR" "$@"
}

set_editor() {
  local chosen="${1:-}"

  if [[ -z "$chosen" ]]; then
    local candidates=(nvim micro nano vim code cursor subl vi)
    local available=()
    local c
    for c in "${candidates[@]}"; do
      command -v "$c" &>/dev/null && available+=("$c")
    done
    ((${#available[@]} == 0)) && available=(nano vim vi)

    echo "=== Select Default Editor ==="
    local i
    for i in "${!available[@]}"; do
      local tag=""
      [[ "${EDITOR:-}" == "${available[i]}" ]] && tag=" [current]"
      printf "  %d) %s%s\n" "$((i + 1))" "${available[i]}" "$tag"
    done

    printf "\nEnter number (1-%d) or custom command: " "${#available[@]}"
    local input
    read -r input || return 1
    [[ -z "$input" ]] && return 0

    if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= ${#available[@]})); then
      chosen="${available[input - 1]}"
    else
      chosen="$input"
    fi
  fi

  if ! command -v "$chosen" &>/dev/null; then
    echo "⚠️  Warning: Command '$chosen' not found on PATH. Setting anyway..." >&2
  fi

  export EDITOR="$chosen"
  export VISUAL="$chosen"

  # Persist across sessions in ~/.env
  local env_file="$HOME/.env"
  touch "$env_file"
  local tmp_dir
  if declare -F _get_zen_tmp_dir >/dev/null 2>&1; then
    tmp_dir="$(_get_zen_tmp_dir)"
  else
    tmp_dir="${TMPDIR:-/tmp}/zencli"
    [[ -d "$tmp_dir" ]] || mkdir -p "$tmp_dir" 2>/dev/null || true
  fi

  if grep -qE '^[[:space:]]*export[[:space:]]+EDITOR=' "$env_file" 2>/dev/null; then
    local tmp; tmp="$(mktemp "${tmp_dir}/env.XXXXXX")"
    sed "s|^[[:space:]]*export[[:space:]]\+EDITOR=.*|export EDITOR=\"$chosen\"|" "$env_file" > "$tmp" && mv "$tmp" "$env_file"
  elif grep -qE '^[[:space:]]*EDITOR=' "$env_file" 2>/dev/null; then
    local tmp; tmp="$(mktemp "${tmp_dir}/env.XXXXXX")"
    sed "s|^[[:space:]]*EDITOR=.*|EDITOR=\"$chosen\"|" "$env_file" > "$tmp" && mv "$tmp" "$env_file"
  else
    printf 'export EDITOR="%s"\n' "$chosen" >> "$env_file"
  fi

  echo "✓ Default EDITOR set and persisted to '$chosen' in ~/.env"
}
