#!/usr/bin/env bash
set -e

REPO="https://github.com/venhdev/zen.git"
DIR="${ZEN_DIR:-${DOTFILES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zen}}"
LEGACY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
LEGACY_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
TARGET_STATE_DIR="${ZEN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zen}"

# Load SSOT platform detection library if present, or provide minimal bootstrap fallbacks
if [[ -f "$DIR/core/00-platform-lib.sh" ]]; then
  . "$DIR/core/00-platform-lib.sh"
elif [[ -f "${BASH_SOURCE[0]%/*}/core/00-platform-lib.sh" ]]; then
  . "${BASH_SOURCE[0]%/*}/core/00-platform-lib.sh"
else
  is_darwin() { [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; }
  is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ "$(uname -r 2>/dev/null)" == *[Mm]icrosoft* ]] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; }
  is_msys() { [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$(uname -s 2>/dev/null)" == MSYS* || "$(uname -s 2>/dev/null)" == MINGW* ]]; }
  has_apt() { command -v apt-get >/dev/null 2>&1; }
fi

# Auto-detect shell RC target (Zsh on macOS/Linux vs standard Bash)
if [[ -n "${DOTFILES_BASHRC:-}" ]]; then
  RC_FILE="$DOTFILES_BASHRC"
elif [[ "${SHELL:-}" == *"zsh"* ]] || { is_darwin && [[ -f "$HOME/.zshrc" ]]; }; then
  RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
else
  RC_FILE="$HOME/.bashrc"
fi
BASHRC="$RC_FILE"
MARKER="# Load Zen"

# Parse CLI arguments
OPT_ALL=0
OPT_FORCE=0
OPT_CLEAN=0
OPT_MODULES=()
for arg in "$@"; do
  case "$arg" in
    -a|--all)
      OPT_ALL=1
      ;;
    -f|--force)
      OPT_FORCE=1
      ;;
    -c|--clean)
      OPT_CLEAN=1
      ;;
    -h|--help)
      echo "Usage: ./install.sh [OPTIONS] [MODULE...]"
      echo
      echo "Options:"
      echo "  -a, --all    Install all modules with defaults (non-interactive)"
      echo "  -f, --force  Force re-installation even if already up to date"
      echo "  -c, --clean  Wipe previous installation directory before installing"
      echo "  -h, --help   Show this help message"
      echo
      echo "Modules: ssh, wsl, mobile, docker, ai, gitconfig (or git), tools, tz (timezone)"
      exit 0
      ;;
    ssh|wsl|mobile|docker|ai|git|gitconfig|zen|vdots|dtools|tools|tz|timezone)
      OPT_MODULES+=("$arg")
      ;;
  esac
done

if [[ "${OPT_MODULES[*]}" == "zen" || "${OPT_MODULES[*]}" == "vdots" || "${OPT_MODULES[*]}" == "dtools" || "${OPT_MODULES[*]}" == "tools" ]]; then
  exec bash "$DIR/scripts/install-tools.sh"
fi

is_worktree_dirty() {
  [[ -n "$(git -C "$DIR" status --porcelain)" ]]
}

is_local_change_pull_error() {
  case "$1" in
    *"would be overwritten by merge"*|\
    *"Please commit your changes or stash them before you merge."*|\
    *"cannot pull with rebase: You have unstaged changes"*|\
    *"cannot pull with rebase: Your index contains uncommitted changes."*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

can_prompt_interactively() {
  { exec 3<>/dev/tty; } 2>/dev/null || return 1
  exec 3>&-
}

prompt_yes_no() {
  local answer
  while true; do
    printf "%s [y/n]: " "$1" > /dev/tty
    IFS= read -r answer < /dev/tty || return 1
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) printf "Please answer y or n (y to proceed, n to cancel).\n" > /dev/tty ;;
    esac
  done
}

restore_cursor() {
  tput cnorm >/dev/tty 2>/dev/null || printf "\033[?25h" >/dev/tty 2>/dev/null || true
}

handle_cancel() {
  restore_cursor
  printf "\n\033[90mInstallation cancelled.\033[0m\n" >/dev/tty 2>/dev/null || printf "\nInstallation cancelled.\n"
  exit 130
}

trap restore_cursor EXIT
trap handle_cancel INT TERM

# --- Generic TUI Engine ---

_tui_select_one() {
  local title="$1" subtitle="$2" selected_out="$3"
  shift 3
  local items=("$@")
  local count=${#items[@]}
  local cursor=0 key seq idx i

  if [[ -n "${!selected_out:-}" ]]; then
    for ((idx=0; idx<count; idx++)); do
      if [[ "${items[idx]}" == "${!selected_out}" || "$idx" == "${!selected_out}" ]]; then
        cursor=$idx
        break
      fi
    done
  fi

  tput civis >/dev/tty 2>/dev/null || printf "\033[?25l" >/dev/tty

  while true; do
    printf "\033[H\033[2J" >/dev/tty
    printf "\033[1;36m=== %s ===\033[0m\n" "$title" >/dev/tty
    [[ -n "$subtitle" ]] && printf "\033[1;34m--- %s ---\033[0m\n" "$subtitle" >/dev/tty
    printf "\033[90m[↑/↓] Navigate | [Enter] Confirm | [q] Cancel\033[0m\n\n" >/dev/tty

    for ((i=0; i<count; i++)); do
      if (( i == cursor )); then
        printf " \033[1;32m> %s\033[0m\n" "${items[i]}" >/dev/tty
      else
        printf "   %s\n" "${items[i]}" >/dev/tty
      fi
    done
    printf "\n" >/dev/tty

    IFS= read -rsn1 key < /dev/tty
    if [[ $key == $'\x1b' ]]; then
      read -rsn2 -t 0.1 seq < /dev/tty || true
      case "$seq" in
        "[A"|"OA") if ((cursor > 0)); then cursor=$((cursor - 1)); else cursor=$((count - 1)); fi ;;
        "[B"|"OB") if ((cursor < count - 1)); then cursor=$((cursor + 1)); else cursor=0; fi ;;
      esac
    elif [[ $key == "k" || $key == "K" ]]; then
      if ((cursor > 0)); then cursor=$((cursor - 1)); else cursor=$((count - 1)); fi
    elif [[ $key == "j" || $key == "J" ]]; then
      if ((cursor < count - 1)); then cursor=$((cursor + 1)); else cursor=0; fi
    elif [[ $key == "q" || $key == "Q" || $key == $'\x03' ]]; then
      handle_cancel
    elif [[ $key == "" || $key == $'\r' || $key == $'\n' ]]; then
      break
    fi
  done
  restore_cursor

  printf -v "$selected_out" "%s" "$cursor"
}

_tui_select_many() {
  local title="$1" subtitle="$2" state_ref="$3" has_toggle_all="$4"
  shift 4
  local labels=("$@")
  local count=${#labels[@]}
  local cursor=0 key seq idx i
  local -n sel="$state_ref"

  tput civis >/dev/tty 2>/dev/null || printf "\033[?25l" >/dev/tty

  while true; do
    printf "\033[H\033[2J" >/dev/tty
    printf "\033[1;36m=== %s ===\033[0m\n" "$title" >/dev/tty
    [[ -n "$subtitle" ]] && printf "\033[1;34m--- %s ---\033[0m\n" "$subtitle" >/dev/tty
    if (( has_toggle_all )); then
      printf "\033[90m[↑/↓] Navigate | [Space] Toggle | [a] Toggle All | [Enter] Confirm | [q] Cancel\033[0m\n\n" >/dev/tty
    else
      printf "\033[90m[↑/↓] Navigate | [Space] Toggle | [Enter] Confirm | [q] Cancel\033[0m\n\n" >/dev/tty
    fi

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

      if (( i == cursor )); then
        printf " \033[1;32m> [%s] %s\033[0m\n" "$mark" "${labels[i]}" >/dev/tty
      else
        printf "   [%s] %s\n" "$mark" "${labels[i]}" >/dev/tty
      fi
    done
    printf "\n" >/dev/tty

    IFS= read -rsn1 key < /dev/tty
    if [[ $key == $'\x1b' ]]; then
      read -rsn2 -t 0.1 seq < /dev/tty || true
      case "$seq" in
        "[A"|"OA") if ((cursor > 0)); then cursor=$((cursor - 1)); else cursor=$((count - 1)); fi ;;
        "[B"|"OB") if ((cursor < count - 1)); then cursor=$((cursor + 1)); else cursor=0; fi ;;
      esac
    elif [[ $key == "k" || $key == "K" ]]; then
      if ((cursor > 0)); then cursor=$((cursor - 1)); else cursor=$((count - 1)); fi
    elif [[ $key == "j" || $key == "J" ]]; then
      if ((cursor < count - 1)); then cursor=$((cursor + 1)); else cursor=0; fi
    elif [[ $key == "a" || $key == "A" ]] && (( has_toggle_all )); then
      local all_on=1
      for ((idx=1; idx<count; idx++)); do
        (( sel[idx] == 0 )) && { all_on=0; break; }
      done
      for ((idx=1; idx<count; idx++)); do
        sel[idx]=$(( 1 - all_on ))
      done
    elif [[ $key == " " ]]; then
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
    elif [[ $key == "q" || $key == "Q" || $key == $'\x03' ]]; then
      handle_cancel
    elif [[ $key == "" || $key == $'\r' || $key == $'\n' ]]; then
      break
    fi
  done
  restore_cursor
}

# --- Declarative Windows Tool Registry & Probe ---

_probe_windows_tools() {
  local win_dir="$1"
  local win_drive="${win_dir%%/Windows*}"
  [[ -z "$win_drive" ]] && win_drive="$(dirname "$win_dir")"
  [[ -z "$win_drive" || "$win_drive" == "." ]] && win_drive="/mnt/c"

  local registry=(
    "chrome|Google Chrome (Flutter Web)|$win_drive/Program Files/Google/Chrome/Application/chrome.exe:$win_drive/Program Files (x86)/Google/Chrome/Application/chrome.exe|mobile"
    "clip|clip.exe (Windows Clipboard)|$win_dir/System32/clip.exe|wsl"
    "explorer|explorer.exe (File Explorer)|$win_dir/explorer.exe|wsl"
    "powershell|powershell.exe (PowerShell)|$win_dir/System32/WindowsPowerShell/v1.0/powershell.exe|wsl"
    "cmd|cmd.exe (Command Prompt)|$win_dir/System32/cmd.exe|wsl"
  )

  tool_ids=()
  tool_names=()
  tool_paths=()
  tool_labels=()
  tool_available=()
  tool_selected=()

  local entry id name paths cat found_path p
  for entry in "${registry[@]}"; do
    IFS='|' read -r id name paths cat <<< "$entry"
    found_path=""
    IFS=':' read -ra cand_array <<< "$paths"
    for p in "${cand_array[@]}"; do
      if [[ -x "$p" || -f "$p" ]]; then
        found_path="$p"
        break
      fi
    done

    tool_ids+=("$id")
    tool_names+=("$name")
    tool_paths+=("$found_path")

    if [[ -n "$found_path" ]]; then
      tool_available+=(1)
      tool_selected+=(1)
      tool_labels+=("$name [Found]")
    else
      tool_available+=(0)
      tool_selected+=(0)
      tool_labels+=("$name [Not found]")
    fi
  done
}

# 0. Clean or Migrate from legacy ~/.config/dotfiles to ~/.config/zen
if (( OPT_CLEAN )); then
  if [[ -d "$DIR" ]]; then
    echo "==> Cleaning previous installation directory at $DIR..."
    rm -rf "$DIR"
  fi
  if [[ -d "$LEGACY_DIR" ]]; then
    echo "==> Cleaning legacy dotfiles directory at $LEGACY_DIR..."
    rm -rf "$LEGACY_DIR"
  fi
  if [[ -d "$LEGACY_STATE_DIR" ]]; then
    echo "==> Cleaning legacy state directory at $LEGACY_STATE_DIR..."
    rm -rf "$LEGACY_STATE_DIR"
  fi
elif [[ -d "$LEGACY_DIR" && "$DIR" != "$LEGACY_DIR" ]]; then
  echo "==> Migrating legacy installation from $LEGACY_DIR to $DIR..."
  if [[ ! -d "$DIR" ]]; then
    mv "$LEGACY_DIR" "$DIR"
    git -C "$DIR" remote set-url origin "$REPO" 2>/dev/null || true
  else
    [[ -f "$LEGACY_DIR/.installed.json" && ! -f "$DIR/.installed.json" ]] && cp "$LEGACY_DIR/.installed.json" "$DIR/"
    [[ -f "$LEGACY_DIR/local/local.env" && ! -f "$DIR/local/local.env" ]] && cp "$LEGACY_DIR/local/local.env" "$DIR/local/"
    rm -rf "$LEGACY_DIR"
  fi
  echo "✔ Successfully migrated to $DIR and cleaned up $LEGACY_DIR"
fi

# Always migrate legacy state directory (~/.local/state/dotfiles -> ~/.local/state/zen)
if [[ -d "$LEGACY_STATE_DIR" ]]; then
  echo "==> Migrating legacy state directory from $LEGACY_STATE_DIR to $TARGET_STATE_DIR..."
  mkdir -p "$TARGET_STATE_DIR" 2>/dev/null || true
  if [[ -f "$LEGACY_STATE_DIR/commands.log" && ! -f "$TARGET_STATE_DIR/commands.log" ]]; then
    mv "$LEGACY_STATE_DIR/commands.log" "$TARGET_STATE_DIR/commands.log" 2>/dev/null || true
  elif [[ -f "$LEGACY_STATE_DIR/commands.log" && -f "$TARGET_STATE_DIR/commands.log" ]]; then
    cat "$LEGACY_STATE_DIR/commands.log" >> "$TARGET_STATE_DIR/commands.log" 2>/dev/null || true
    rm -f "$LEGACY_STATE_DIR/commands.log" 2>/dev/null || true
  fi
  rm -rf "$LEGACY_STATE_DIR" 2>/dev/null || true
  echo "✔ Successfully migrated state directory to $TARGET_STATE_DIR"
fi

# 1. Update or clone repository
if [[ -n "${DOTFILES_REEXEC:-}" ]]; then
  ACTION=updated
elif [[ -d "$DIR/.git" ]]; then
  if pull_output="$(git -C "$DIR" pull --ff-only 2>&1)"; then
    [ -n "$pull_output" ] && printf '%s\n' "$pull_output"
    ACTION=updated

    # If already up to date, dotfiles is configured, and running non-interactive --all without force flag:
    if [[ "$pull_output" == *"Already up to date."* && -f "$DIR/local/local.env" ]]; then
      if (( OPT_ALL )) && (( ${#OPT_MODULES[@]} == 0 )) && (( ${OPT_FORCE:-0} == 0 )); then
        exit 0
      fi
    fi
  else
    pull_exit=$?
    if is_worktree_dirty && is_local_change_pull_error "$pull_output"; then
      printf '%s\n' "$pull_output" >&2
      if ! can_prompt_interactively; then
        echo "Cannot prompt to force update without an interactive terminal." >&2
        echo "Please stash or commit your local changes in $DIR, then re-run install.sh." >&2
        exit "$pull_exit"
      fi

      if prompt_yes_no "Local changes detected in $DIR. Stash changes and force update?"; then
        stash_message="dotfiles installer auto-stash $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        git -C "$DIR" stash push -u -m "$stash_message" >/dev/null
        stash_ref="$(git -C "$DIR" rev-parse --short -q --verify refs/stash)"

        if pull_output="$(git -C "$DIR" pull --ff-only 2>&1)"; then
          [ -n "$pull_output" ] && printf '%s\n' "$pull_output"
          ACTION=updated
          echo "Stashed local changes before update as stash@{0} (${stash_ref})."
          echo "Re-apply when ready with: git -C \"$DIR\" stash pop"
        else
          printf '%s\n' "$pull_output" >&2
          echo "Update failed after stashing. Your local changes are preserved in stash@{0} (${stash_ref})." >&2
          echo "Recover with: git -C \"$DIR\" stash pop" >&2
          exit 1
        fi
      else
        echo "Install cancelled: leaving local checkout unchanged at $DIR." >&2
        exit 1
      fi
    else
      printf '%s\n' "$pull_output" >&2
      exit "$pull_exit"
    fi
  fi
else
  # If running in local checkout not at $DIR, copy or clone
  if [[ ! -d "$DIR" ]]; then
    git clone "$REPO" "$DIR"
    ACTION=installed
  else
    ACTION=updated
  fi
fi

# Hand over execution to local script in $DIR if running from pipe/stdin or updated
if [[ -z "${DOTFILES_REEXEC:-}" ]]; then
  current_script=""
  [[ -n "${BASH_SOURCE[0]:-}" ]] && current_script="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  target_script="$(readlink -f "$DIR/install.sh" 2>/dev/null || true)"

  if [[ -z "$current_script" || "$current_script" != "$target_script" || "${pull_output:-}" != *"Already up to date."* ]]; then
    export DOTFILES_REEXEC=1
    if can_prompt_interactively && [[ ! -t 0 ]]; then
      exec bash "$DIR/install.sh" "$@" < /dev/tty
    else
      exec bash "$DIR/install.sh" "$@"
    fi
  fi
fi

# 2. Existing local config detection
existing_ssh_init=""
existing_win_path=""
existing_chrome_path=""
existing_tz=""
if [[ -f "$DIR/local/local.env" ]]; then
  existing_ssh_init="$(grep -E '^export DOTFILES_SSH_INIT=' "$DIR/local/local.env" | cut -d'"' -f2 || true)"
  existing_win_path="$(grep -E '^export DOTFILES_WIN_PATH=' "$DIR/local/local.env" | cut -d'"' -f2 || true)"
  existing_chrome_path="$(grep -E '^export CHROME_EXECUTABLE=' "$DIR/local/local.env" | cut -d'"' -f2 || true)"
  existing_tz="$(grep -E '^export TZ=' "$DIR/local/local.env" | cut -d'"' -f2 || true)"
fi

detected_ssh_keys=()
if [[ -d "$HOME/.ssh" ]]; then
  while IFS= read -r -d "" file; do
    detected_ssh_keys+=("$file")
  done < <(find "$HOME/.ssh" -maxdepth 1 -type f \
    \( -name "*_ed25519" -o -name "*_rsa" -o -name "*_ecdsa" -o -name "id_*" \) \
    ! -name "*.pub" ! -name "known_hosts*" ! -name "config" ! -name "authorized_keys*" \
    ! -name "*.old" ! -name "*.bak" -print0 2>/dev/null | sort -z)
fi

auto_key=""
if (( ${#detected_ssh_keys[@]} > 0 )); then
  auto_key="${detected_ssh_keys[0]}"
fi
default_ssh="${existing_ssh_init:-$auto_key}"
if [[ -n "${existing_win_path:-}" ]]; then
  default_win="$existing_win_path"
elif [[ -n "${_WIN_DIR:-}" ]]; then
  default_win="$_WIN_DIR"
elif [[ -d "/c/Windows" ]]; then
  default_win="/c/Windows"
else
  default_win="/mnt/c/Windows"
fi

auto_tz=""
if [[ -n "$existing_tz" ]]; then
  auto_tz="$existing_tz"
else
  # Check Windows host timezone via tzutil.exe if on WSL
  if is_wsl; then
    tzutil_bin="${existing_win_path:-$default_win}/System32/tzutil.exe"
    [[ ! -x "$tzutil_bin" ]] && tzutil_bin="/mnt/c/Windows/System32/tzutil.exe"
    if [[ -x "$tzutil_bin" ]]; then
      win_tz="$("$tzutil_bin" /g 2>/dev/null | tr -d '\r\n' || true)"
      case "$win_tz" in
        *"SE Asia"*|*"Bangkok"*|*"Hanoi"*|*"Jakarta"*)
          auto_tz="Asia/Ho_Chi_Minh"
          ;;
        *"Singapore"*)
          auto_tz="Asia/Singapore"
          ;;
        *"Tokyo"*)
          auto_tz="Asia/Tokyo"
          ;;
        *"Korea"*)
          auto_tz="Asia/Seoul"
          ;;
        *"China"*)
          auto_tz="Asia/Shanghai"
          ;;
        *"Taipei"*)
          auto_tz="Asia/Taipei"
          ;;
      esac
    fi
  fi
  # Fallback to Asia/Ho_Chi_Minh or current TZ
  [[ -z "$auto_tz" ]] && auto_tz="${TZ:-Asia/Ho_Chi_Minh}"
fi
default_tz="$auto_tz"

# Module definitions:
# index 0: [ALL]
# index 1: ssh
# index 2: wsl
# index 3: mobile
# index 4: docker
# index 5: ai
# index 6: gitconfig
modules=("ALL" "ssh" "wsl" "mobile" "docker" "ai" "gitconfig" "tools")
menu_labels=(
  "[ALL] Select / Deselect all modules"
  "ssh       - SSH Manager (Auto ssh-agent & SSH key loading)"
  "wsl       - WSL Integration (clip, explorer, winpath, wcp)"
  "mobile    - Mobile Dev (Flutter, Shorebird, Android ADB tools)"
  "docker    - Docker Shortcuts (dps, dcl cleanup)"
  "ai        - AI & Agent Tools (Claude, OpenClaw, Skills CLI)"
  "gitconfig - Git Aliases & Config (lg, lga, inf, br, co, ...)"
  "tools     - Common CLI Tools (Debian/Ubuntu apt: git, curl, jq, rg)"
)
num_items=${#modules[@]}
selected=(0 0 0 0 0 0 0 0)

# Pre-select initial state based on environment or existing symlinks
if [[ -L "$DIR/enabled.d/50-ssh.sh" ]]; then
  selected[1]=1
elif [[ -n "$auto_key" || -n "$existing_ssh_init" ]]; then
  selected[1]=1
fi

if [[ -L "$DIR/enabled.d/50-wsl.sh" ]]; then
  selected[2]=1
elif is_wsl; then
  selected[2]=1
fi

if [[ -L "$DIR/enabled.d/50-mobile.sh" ]]; then
  selected[3]=1
fi

if [[ -L "$DIR/enabled.d/50-docker.sh" ]]; then
  selected[4]=1
elif command -v docker >/dev/null 2>&1; then
  selected[4]=1
fi

if [[ -L "$DIR/enabled.d/50-ai.sh" ]]; then
  selected[5]=1
elif command -v claude >/dev/null 2>&1 || [[ -d "$HOME/.openclaw" || -d "$HOME/.claude" ]]; then
  selected[5]=1
fi

GIT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.gitconfig"
OLD_GIT_ALIASES_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.gitconfig_aliases"
if git config --global --get-all include.path 2>/dev/null | grep -Fxq "$GIT_CONFIG_FILE"; then
  selected[6]=1
elif command -v git >/dev/null 2>&1; then
  selected[6]=1
fi

_prompt_ssh_key() {
  local num_detected=${#detected_ssh_keys[@]}
  if (( num_detected > 0 )); then
    local ssh_menu_items=() k base_name ssh_choice=0 k_idx input_ssh
    for k in "${detected_ssh_keys[@]}"; do
      base_name="$(basename "$k")"
      ssh_menu_items+=("$base_name (~/.ssh/$base_name)")
    done
    ssh_menu_items+=("[None] Skip SSH auto-load")
    ssh_menu_items+=("[Custom] Enter path manually...")

    if [[ -n "$existing_ssh_init" ]]; then
      for ((k_idx=0; k_idx<num_detected; k_idx++)); do
        if [[ "${detected_ssh_keys[k_idx]}" == "$existing_ssh_init" ]]; then
          ssh_choice=$k_idx
          break
        fi
      done
    fi

    _tui_select_one "DOTFILES CONFIGURATION" "SSH Key Selection" ssh_choice "${ssh_menu_items[@]}"

    if (( ssh_choice < num_detected )); then
      ssh_init_val="${detected_ssh_keys[ssh_choice]}"
    elif (( ssh_choice == num_detected )); then
      ssh_init_val=""
    else
      printf "Custom SSH key path (leave empty to skip): " >/dev/tty
      IFS= read -r input_ssh < /dev/tty
      ssh_init_val="${input_ssh:-}"
    fi
  else
    printf "No SSH keys found in ~/.ssh.\n" >/dev/tty
    printf "SSH key path to auto-load (press Enter to skip): " >/dev/tty
    IFS= read -r input_ssh < /dev/tty
    ssh_init_val="${input_ssh:-}"
  fi
}

_prompt_win_tools() {
  local win_menu_items=() win_choice=0 input_win t
  if [[ -d "$default_win" ]]; then
    win_menu_items+=("$default_win")
  else
    win_menu_items+=("/mnt/c/Windows")
  fi
  win_menu_items+=("[None] Skip Windows integration")
  win_menu_items+=("[Custom] Enter path manually...")

  [[ -z "$existing_win_path" && ! -d "$default_win" ]] && win_choice=1

  _tui_select_one "DOTFILES CONFIGURATION" "Windows Path Selection" win_choice "${win_menu_items[@]}"

  if (( win_choice == 0 )); then
    win_path_val="${win_menu_items[0]}"
  elif (( win_choice == 1 )); then
    win_path_val=""
  else
    printf "Custom Windows path (leave empty to skip): " >/dev/tty
    IFS= read -r input_win < /dev/tty
    win_path_val="${input_win:-}"
  fi

  if [[ -n "$win_path_val" && "$win_path_val" != "none" && -d "$win_path_val" ]]; then
    _probe_windows_tools "$win_path_val"
    _tui_select_many "DOTFILES CONFIGURATION" "Windows Tools Selection" tool_selected 0 "${tool_labels[@]}"

    for ((t=0; t<${#tool_ids[@]}; t++)); do
      if (( tool_selected[t] )); then
        if [[ "${tool_ids[t]}" == "chrome" && -n "${tool_paths[t]}" ]]; then
          chrome_path_val="${tool_paths[t]}"
        fi
      fi
    done
  fi
}

_prompt_timezone() {
  local tz_menu_items=(
    "Asia/Ho_Chi_Minh  (UTC+7 - Vietnam, ICT)"
    "Etc/UTC           (UTC+0 - Coordinated Universal Time)"
    "[Keep System]     (Do not export TZ variable)"
    "[Custom]          Enter IANA Timezone manually..."
  )
  local tz_choice=0
  if [[ "$default_tz" == "Etc/UTC" || "$default_tz" == "UTC" ]]; then
    tz_choice=1
  elif [[ -z "$default_tz" ]]; then
    tz_choice=2
  elif [[ "$default_tz" != "Asia/Ho_Chi_Minh" ]]; then
    tz_choice=3
  fi

  _tui_select_one "DOTFILES CONFIGURATION" "Timezone Selection (UTC / Local)" tz_choice "${tz_menu_items[@]}"

  case "$tz_choice" in
    0) tz_val="Asia/Ho_Chi_Minh" ;;
    1) tz_val="Etc/UTC" ;;
    2) tz_val="" ;;
    3)
      printf "Enter IANA Timezone (e.g. Asia/Tokyo, America/New_York): " >/dev/tty
      local input_tz
      IFS= read -r input_tz < /dev/tty
      tz_val="${input_tz:-Asia/Ho_Chi_Minh}"
      ;;
  esac
}

# 3. Interactive Selection or Non-interactive Fallback
ssh_init_val="$default_ssh"
win_path_val="$default_win"
chrome_path_val="$existing_chrome_path"
tz_val="$default_tz"

target_ssh_prompt=0
target_win_prompt=0
target_tz_prompt=0

if (( ${#OPT_MODULES[@]} > 0 )); then
  for m in "${OPT_MODULES[@]}"; do
    case "$m" in
      ssh) selected[1]=1; target_ssh_prompt=1 ;;
      wsl) selected[2]=1; target_win_prompt=1 ;;
      mobile) selected[3]=1; target_win_prompt=1 ;;
      docker) selected[4]=1 ;;
      ai) selected[5]=1 ;;
      git|gitconfig) selected[6]=1 ;;
      tools) selected[7]=1 ;;
      tz|timezone) target_tz_prompt=1 ;;
    esac
  done
fi

if (( OPT_ALL )); then
  for ((idx=1; idx<num_items; idx++)); do
    selected[idx]=1
  done
  # On systems without apt (e.g. Windows Git Bash, macOS, non-Debian Linux),
  # do not auto-select the apt-based tools installer during --all
  if ! has_apt; then
    selected[7]=0
  fi
  if [[ -d "$default_win" ]]; then
    win_path_val="$default_win"
    _probe_windows_tools "$win_path_val"
    for ((t=0; t<${#tool_ids[@]}; t++)); do
      if (( tool_available[t] )); then
        if [[ "${tool_ids[t]}" == "chrome" && -n "${tool_paths[t]}" ]]; then
          chrome_path_val="${tool_paths[t]}"
        fi
      fi
    done
  fi
elif can_prompt_interactively; then
  if (( ${#OPT_MODULES[@]} > 0 )); then
    # User specified targeted module(s) via CLI (e.g. insssh, insmobile)
    (( target_ssh_prompt )) && _prompt_ssh_key
    (( target_win_prompt )) && _prompt_win_tools
    (( target_tz_prompt )) && _prompt_timezone
  else
    _tui_select_many "DOTFILES MODULE SELECTOR" "" selected 1 "${menu_labels[@]}"

    # Dynamic Configuration Prompts
    if (( selected[1] || selected[2] || selected[3] )); then
      (( selected[1] )) && _prompt_ssh_key
      (( selected[2] || selected[3] )) && _prompt_win_tools
    fi
    _prompt_timezone
  fi
  # Summary and Confirmation
  printf "\n\033[1;36m================ INSTALLATION SUMMARY ================\033[0m\n" >/dev/tty
  printf " Core: shell-lib, base-aliases, editor-lib, config-lib, info-lib (Always enabled)\n" >/dev/tty
  printf " Modules:\n" >/dev/tty
  if (( selected[1] )); then
    if [[ -n "$ssh_init_val" ]]; then
      printf "   \033[1;32m[✔] ssh\033[0m       -> Key: %s\n" "$ssh_init_val" >/dev/tty
    else
      printf "   \033[1;32m[✔] ssh\033[0m       -> Key: (None - auto-load skipped)\n" >/dev/tty
    fi
  else
    printf "   \033[90m[ ] ssh       -> Disabled\033[0m\n" >/dev/tty
  fi

  if (( selected[2] )); then
    wsl_path_info=""
    if is_wsl; then
      ap_val=$(awk -F'=' '/^[[:space:]]*appendWindowsPath[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); val=tolower($2)} END {if (val=="false" || val=="true") print val; else print "default/true"}' /etc/wsl.conf 2>/dev/null || echo "default/true")
      wsl_path_info=" (appendWindowsPath: $ap_val)"
    fi
    if [[ -n "$win_path_val" ]]; then
      printf "   \033[1;32m[✔] wsl\033[0m       -> WinPath: %s%s\n" "$win_path_val" "$wsl_path_info" >/dev/tty
    else
      printf "   \033[1;32m[✔] wsl\033[0m       -> (None - Windows path skipped)%s\n" "$wsl_path_info" >/dev/tty
    fi
  else
    printf "   \033[90m[ ] wsl       -> Disabled\033[0m\n" >/dev/tty
  fi

  if (( selected[3] )); then
    if [[ -n "$chrome_path_val" ]]; then
      printf "   \033[1;32m[✔] mobile\033[0m    -> Flutter, Shorebird, ADB | Chrome: %s\n" "$chrome_path_val" >/dev/tty
    else
      printf "   \033[1;32m[✔] mobile\033[0m    -> Flutter, Shorebird, ADB tools enabled\n" >/dev/tty
    fi
  else
    printf "   \033[90m[ ] mobile    -> Disabled\033[0m\n" >/dev/tty
  fi

  if (( selected[4] )); then
    printf "   \033[1;32m[✔] docker\033[0m    -> Docker shortcuts enabled\n" >/dev/tty
  else
    printf "   \033[90m[ ] docker    -> Disabled\033[0m\n" >/dev/tty
  fi

  if (( selected[5] )); then
    printf "   \033[1;32m[✔] ai\033[0m        -> Claude, OpenClaw, Skills CLI enabled\n" >/dev/tty
  else
    printf "   \033[90m[ ] ai        -> Disabled\033[0m\n" >/dev/tty
  fi

  if (( selected[6] )); then
    printf "   \033[1;32m[✔] gitconfig\033[0m -> Git Aliases & Config (include.path enabled)\n" >/dev/tty
  else
    printf "   \033[90m[ ] gitconfig -> Disabled\033[0m\n" >/dev/tty
  fi

  if (( selected[7] )); then
    printf "   \033[1;32m[✔] tools\033[0m     -> Common CLI tools (git, curl, jq, rg)\n" >/dev/tty
  else
    printf "   \033[90m[ ] tools     -> Disabled\033[0m\n" >/dev/tty
  fi

  if [[ -n "$tz_val" ]]; then
    printf "   \033[1;32m[✔] timezone\033[0m  -> %s\n" "$tz_val" >/dev/tty
  else
    printf "   \033[90m[ ] timezone  -> System Default (unchanged)\033[0m\n" >/dev/tty
  fi
  printf "\n" >/dev/tty

  if ! prompt_yes_no "Proceed with installation?"; then
    echo "Installation cancelled." >&2
    exit 1
  fi
fi

# 4. Apply Configuration and Setup Symlinks
mkdir -p "$DIR/local" "$DIR/enabled.d"

# Write local.env
cat > "$DIR/local/local.env.tmp" <<EOF
# Machine-specific local configuration (managed by dotfiles install.sh)
export DOTFILES_SSH_INIT="${ssh_init_val}"
export DOTFILES_WIN_PATH="${win_path_val}"
export CHROME_EXECUTABLE="${chrome_path_val}"
$([[ -n "$tz_val" ]] && echo "export TZ=\"${tz_val}\"")
EOF
chmod 600 "$DIR/local/local.env.tmp"
mv "$DIR/local/local.env.tmp" "$DIR/local/local.env"

# Manifest tracking arrays
MANIFEST_SHELL_HOOKS=("$RC_FILE")
MANIFEST_SYMLINKS=()
MANIFEST_GIT_INCLUDES=()
MANIFEST_TERMINAL_CONFIGS=()

# Symlink Chrome if selected
if [[ -n "$chrome_path_val" && -x "$chrome_path_val" ]]; then
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$chrome_path_val" "$HOME/.local/bin/chrome"
  ln -sfn "$chrome_path_val" "$HOME/.local/bin/google-chrome"
  MANIFEST_SYMLINKS+=("{\"link\": \"$HOME/.local/bin/chrome\", \"target\": \"$chrome_path_val\", \"backup\": null}")
  MANIFEST_SYMLINKS+=("{\"link\": \"$HOME/.local/bin/google-chrome\", \"target\": \"$chrome_path_val\", \"backup\": null}")
fi

# Sync symlinks in enabled.d
rm -f "$DIR/enabled.d"/50-*.sh
(( selected[1] )) && ln -sfn "../modules/ssh/module.sh" "$DIR/enabled.d/50-ssh.sh"
(( selected[2] )) && ln -sfn "../modules/wsl/module.sh" "$DIR/enabled.d/50-wsl.sh"
(( selected[3] )) && ln -sfn "../modules/mobile/module.sh" "$DIR/enabled.d/50-mobile.sh"
(( selected[4] )) && ln -sfn "../modules/docker/module.sh" "$DIR/enabled.d/50-docker.sh"
(( selected[5] )) && ln -sfn "../modules/ai/module.sh" "$DIR/enabled.d/50-ai.sh"

# 5. Update shell configuration ($RC_FILE)
touch "$RC_FILE"

# Clean legacy dotfiles or zen hooks
if grep -Eq '# Load (dotfiles|zen|Zen)' "$RC_FILE" 2>/dev/null; then
  sed -E '/^# Load (dotfiles|zen|Zen)$/,/^unset _(cfg|f) (DOTFILES|ZEN)$/d' "$RC_FILE" > "$RC_FILE.tmp" && mv "$RC_FILE.tmp" "$RC_FILE"
fi

cat >>"$RC_FILE" <<EOF

# Load Zen
ZEN="$DIR"

[ -r "\$ZEN/local/local.env" ] && . "\$ZEN/local/local.env"

for _f in "\$ZEN"/core/*.sh "\$ZEN"/enabled.d/*.sh "\$HOME/.env"; do
  [ -r "\$_f" ] && . "\$_f"
done

unset _f ZEN
EOF

# 6. Global Git Configuration
GIT_CONFIG_FILE="$DIR/.gitconfig"
OLD_GIT_ALIASES_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.gitconfig_aliases"
OLD_GIT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.gitconfig"
if command -v git >/dev/null 2>&1; then
  git config --global --unset-all include.path "$OLD_GIT_ALIASES_FILE" 2>/dev/null || true
  if [[ "$DIR" != "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles" ]]; then
    git config --global --unset-all include.path "$OLD_GIT_CONFIG_FILE" 2>/dev/null || true
  fi
  if (( selected[6] )); then
    if ! git config --global --get-all include.path 2>/dev/null | grep -Fxq "$GIT_CONFIG_FILE"; then
      git config --global --add include.path "$GIT_CONFIG_FILE"
    fi
    MANIFEST_GIT_INCLUDES+=("$GIT_CONFIG_FILE")
  else
    git config --global --unset-all include.path "$GIT_CONFIG_FILE" 2>/dev/null || true
  fi
fi

# 7. Windows PowerShell Integration (when installing from Git Bash/MSYS)
if is_msys; then
  for ps_doc in "$HOME/Documents/PowerShell" "$HOME/Documents/WindowsPowerShell"; do
    ps_prof="$ps_doc/Microsoft.PowerShell_profile.ps1"
    mkdir -p "$ps_doc"
    touch "$ps_prof"
    if ! grep -Eq '# Load (dotfiles|zen|Zen)' "$ps_prof" 2>/dev/null; then
      cat >>"$ps_prof" <<'PS_EOF'

# Load Zen
$global:ZEN_DIR = "$env:USERPROFILE\.config\zen"
$global:DOTFILES_DIR = $global:ZEN_DIR
$zenLoader = "$global:ZEN_DIR\powershell\profile.ps1"
if (Test-Path $zenLoader) { . $zenLoader }
# End Zen
PS_EOF
      MANIFEST_SHELL_HOOKS+=("$ps_prof")
    fi
  done
fi

# 8. Terminal Configuration (Auto-detected)
if command -v tmux >/dev/null 2>&1; then
  tmux_src="$DIR/tmux/.tmux.conf"
  tmux_dst="$HOME/.tmux.conf"
  tmux_bak=""
  if [[ -f "$tmux_src" ]]; then
    if [[ -e "$tmux_dst" && ! -L "$tmux_dst" ]] || { [[ -L "$tmux_dst" ]] && [[ "$(readlink "$tmux_dst" 2>/dev/null)" != "$tmux_src" ]]; }; then
      tmux_bak="$HOME/.tmux.conf.pre-dotfiles.bak"
      cp -f "$tmux_dst" "$tmux_bak" 2>/dev/null || true
    fi
    ln -sfn "$tmux_src" "$tmux_dst"
    MANIFEST_SYMLINKS+=("{\"link\": \"$tmux_dst\", \"target\": \"$tmux_src\", \"backup\": $([[ -n "$tmux_bak" ]] && echo "\"$tmux_bak\"" || echo "null")}")
    echo "✔ tmux detected -> Linked ~/.tmux.conf"
  fi
fi

# 9. Write Installation State Manifest (.installed.json)
write_manifest() {
  local manifest_file="$DIR/.installed.json"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
  
  local shell_hooks_json="[]"
  if ((${#MANIFEST_SHELL_HOOKS[@]} > 0)); then
    local items=()
    for h in "${MANIFEST_SHELL_HOOKS[@]}"; do
      items+=("\"$h\"")
    done
    shell_hooks_json="[ $(IFS=,; echo "${items[*]}") ]"
  fi

  local git_includes_json="[]"
  if ((${#MANIFEST_GIT_INCLUDES[@]} > 0)); then
    local items=()
    for g in "${MANIFEST_GIT_INCLUDES[@]}"; do
      items+=("\"$g\"")
    done
    git_includes_json="[ $(IFS=,; echo "${items[*]}") ]"
  fi

  local symlinks_json="[]"
  if ((${#MANIFEST_SYMLINKS[@]} > 0)); then
    symlinks_json="[ $(IFS=,; echo "${MANIFEST_SYMLINKS[*]}") ]"
  fi

  local terminal_configs_json="[]"
  if ((${#MANIFEST_TERMINAL_CONFIGS[@]} > 0)); then
    terminal_configs_json="[ $(IFS=,; echo "${MANIFEST_TERMINAL_CONFIGS[*]}") ]"
  fi

  local tools_json="{}"
  if [[ -f "$manifest_file" ]] && command -v python3 >/dev/null 2>&1; then
    tools_json="$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])).get("tools", {})))' "$manifest_file" 2>/dev/null || echo "{}")"
  fi

  cat > "$manifest_file.tmp" <<JSON_EOF
{
  "version": "1.1.0",
  "installed_at": "$now",
  "platform": "$_OS_TYPE",
  "shell_hooks": $shell_hooks_json,
  "symlinks": $symlinks_json,
  "git_includes": $git_includes_json,
  "terminal_configs": $terminal_configs_json,
  "tools": $tools_json
}
JSON_EOF
  mv "$manifest_file.tmp" "$manifest_file"
}
write_manifest

# 10. Common CLI Tools (if selected)
if (( selected[7] )); then
  if [[ -f "$DIR/scripts/install-tools.sh" ]]; then
    if (( OPT_ALL )); then
      bash "$DIR/scripts/install-tools.sh" --all
    else
      bash "$DIR/scripts/install-tools.sh"
    fi
  fi
fi

echo
echo "ZenCLI $ACTION successfully: $DIR"
echo
echo "Run below command to reload:"
echo "source ~/.bashrc"
