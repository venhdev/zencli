# Config helpers

conf() {
  local zen_root
  if declare -F _get_zen_root >/dev/null 2>&1; then
    zen_root="$(_get_zen_root)"
  elif declare -F _get_dotfiles_root >/dev/null 2>&1; then
    zen_root="$(_get_dotfiles_root)"
  else
    zen_root="${ZEN_ROOT:-${ZEN_DIR:-${ZEN:-${XDG_CONFIG_HOME:-$HOME/.config}/zen}}}"
  fi

  local -A m=(
    [bashrc]="$HOME/.bashrc"
    [zshrc]="${ZDOTDIR:-$HOME}/.zshrc"
    [platform]="$zen_root/core/00-platform-lib.sh"
    [ali]="$zen_root/core/10-base-aliases.sh"
    [localenv]="$zen_root/local/local.env"
    [ssh]="$HOME/.ssh/config"
    [env]="$HOME/.env"
    [profile]="/etc/profile"
    [pwprofile]="$zen_root/powershell/profile.ps1"
    [git]="$HOME/.gitconfig"
    [gitdot]="$zen_root/.gitconfig"
    [claude]="$HOME/.claude/settings.json"
    [codex]="$HOME/.codex/config.toml"
    [docker]="$HOME/.docker/config.json"
    [oc]="$HOME/.openclaw/openclaw.json"
    [opencode]="$HOME/.config/opencode/opencode.json"
    [cmdlog]="$zen_root/core/15-cmdlog-lib.sh"
    [clog]="$zen_root/core/15-cmdlog-lib.sh"
  )

  local f k="${1:-}" x l
  k="${k#conf }"
  k="${k# }"

  for f in "$zen_root"/core/*.sh "$zen_root"/modules/*/*.sh "$HOME"/bin/*.sh; do
    [[ -e $f ]] && m[$(basename "$f" .sh)]="$f"
  done

  if [[ -z $k ]]; then
    local lines=()

    for x in "${!m[@]}"; do
      lines+=("$(printf '%-10s %s' "$x" "${m[$x]}")")
    done

    mapfile -t lines < <(printf '%s\n' "${lines[@]}" | sort)

    if command -v fzf &>/dev/null; then
      k=$(printf '%s\n' "${lines[@]}" |
        fzf --prompt='Config > ' |
        awk '{print $1}') || return
    else
      select l in "${lines[@]}"; do
        [[ -n $l ]] && { k=${l%% *}; break; }
      done
    fi
    k="${k#conf }"
    k="${k# }"
  fi

  [[ -n ${m[$k]:-} ]] || {
    echo "Unknown: $k" >&2
    return 1
  }

  "$EDITOR" "${m[$k]}"
}
