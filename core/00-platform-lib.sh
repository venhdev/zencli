# Cross-platform environment detection and standard OS primitives (Linux, macOS, Windows)

# Detect Operating System Family
_detect_os() {
  case "$OSTYPE" in
    darwin*)
      echo "darwin"
      return
      ;;
    msys*|cygwin*)
      echo "msys"
      return
      ;;
    linux*)
      if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -f /proc/version && "$(< /proc/version)" == *[Mm]icrosoft* ]]; then
        echo "wsl"
      elif [[ "$(uname -r 2>/dev/null)" == *[Mm]icrosoft* ]]; then
        echo "wsl"
      else
        echo "linux"
      fi
      return
      ;;
  esac

  local uname_out
  uname_out="$(uname -s 2>/dev/null || echo "Unknown")"

  case "$uname_out" in
    Darwin*)
      echo "darwin"
      ;;
    MSYS*|MINGW*|CYGWIN*)
      echo "msys"
      ;;
    Linux*)
      if [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -f /proc/version && "$(< /proc/version)" == *[Mm]icrosoft* ]] || [[ "$(uname -r 2>/dev/null)" == *[Mm]icrosoft* ]]; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# Detect Linux Distribution Family (from /etc/os-release without external subshell forks)
_detect_distro() {
  if [[ -f /etc/os-release ]]; then
    typeset -l id="" id_like=""
    local k v
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
      v="${v%\"}"
      v="${v#\"}"
      v="${v%\'}"
      v="${v#\'}"
      case "$k" in
        ID) id="$v" ;;
        ID_LIKE) id_like="$v" ;;
      esac
      [[ -n "$id" && -n "$id_like" ]] && break
    done < /etc/os-release
    echo "${id:-${id_like:-linux}}"
  else
    echo "unknown"
  fi
}

# Detect Windows Host System Directory
_detect_win_dir() {
  if [[ -n "${DOTFILES_WIN_PATH:-}" && -d "$DOTFILES_WIN_PATH" ]]; then
    echo "$DOTFILES_WIN_PATH"
  elif [[ -d "/c/Windows" ]]; then
    echo "/c/Windows"
  elif [[ -d "/mnt/c/Windows" ]]; then
    echo "/mnt/c/Windows"
  else
    echo "/mnt/c/Windows"
  fi
}

_OS_TYPE="$(_detect_os)"
_LINUX_DISTRO="$(_detect_distro)"
_WIN_DIR="$(_detect_win_dir)"

# SSOT Boolean Helper Functions
is_darwin() { [[ "$_OS_TYPE" == "darwin" ]]; }
is_mac() { is_darwin; }
is_wsl() { [[ "$_OS_TYPE" == "wsl" ]]; }
is_msys() { [[ "$_OS_TYPE" == "msys" ]]; }
is_linux() { [[ "$_OS_TYPE" == "linux" || "$_OS_TYPE" == "wsl" ]]; }
is_pure_linux() { [[ "$_OS_TYPE" == "linux" ]]; }
is_windows() { [[ "$_OS_TYPE" == "msys" || "$_OS_TYPE" == "wsl" ]]; }
has_apt() { command -v apt-get >/dev/null 2>&1; }

# Cross-platform clipboard helper
clip() {
  case "$_OS_TYPE" in
    darwin)
      if command -v pbcopy &>/dev/null; then
        pbcopy "$@"
        return $?
      fi
      ;;
    wsl|msys)
      local clip_exe="${DOTFILES_WIN_PATH:-$_WIN_DIR}/System32/clip.exe"
      if [[ -x "$clip_exe" ]]; then
        "$clip_exe" "$@"
        return $?
      elif command -v clip.exe &>/dev/null; then
        clip.exe "$@"
        return $?
      fi
      ;;
    linux)
      if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy &>/dev/null; then
        wl-copy "$@"
        return $?
      elif command -v xclip &>/dev/null; then
        xclip -selection clipboard "$@"
        return $?
      elif command -v xsel &>/dev/null; then
        xsel --clipboard --input "$@"
        return $?
      fi
      ;;
  esac

  echo "❌ No supported clipboard utility found (pbcopy, clip.exe, wl-copy, xclip, xsel)" >&2
  return 1
}

# Copy Linux path of target (default: current directory $PWD) to clipboard
cpwd() {
  local target="${1:-$PWD}"
  local abs_path
  abs_path="$(readlink -f "$target" 2>/dev/null || realpath "$target" 2>/dev/null || echo "$target")"
  printf '%s' "$abs_path" | clip
  echo "Copied (Linux): $abs_path"
}

# Cross-platform file / URL opener
open_target() {
  local target="${1:-.}"

  case "$_OS_TYPE" in
    darwin)
      open "$target"
      ;;
    wsl)
      if command -v wslpath &>/dev/null && [[ -e "$target" ]]; then
        explorer.exe "$(wslpath -w "$target")"
      else
        explorer.exe "$target"
      fi
      ;;
    msys)
      explorer.exe "$target"
      ;;
    linux)
      if command -v xdg-open &>/dev/null; then
        xdg-open "$target" &>/dev/null &
      else
        echo "❌ xdg-open not found" >&2
        return 1
      fi
      ;;
    *)
      echo "❌ No supported opener found for OS: $_OS_TYPE" >&2
      return 1
      ;;
  esac
}

# ==============================================================================
# ZENCLI ECOSYSTEM METADATA & DYNAMIC PATHS CONTRACT
# ==============================================================================
_ZEN_APP_NAME="zencli"
_ZEN_APP_SHORT="zen"
_ZEN_APP_DISPLAY="ZenCLI"

# Dynamic Root Directory Resolver
_get_zen_root() {
  if [[ -n "${ZENCLI_ROOT:-}" && -d "$ZENCLI_ROOT" ]]; then
    echo "$ZENCLI_ROOT"
    return
  fi
  if [[ -n "${ZENCLI_DIR:-}" && -d "$ZENCLI_DIR" ]]; then
    echo "$ZENCLI_DIR"
    return
  fi
  if [[ -n "${ZENCLI:-}" && -d "$ZENCLI" ]]; then
    echo "$ZENCLI"
    return
  fi
  if [[ -n "${ZEN_ROOT:-}" && -d "$ZEN_ROOT" ]]; then
    echo "$ZEN_ROOT"
    return
  fi
  if [[ -n "${ZEN_DIR:-}" && -d "$ZEN_DIR" ]]; then
    echo "$ZEN_DIR"
    return
  fi
  if [[ -n "${ZEN:-}" && -d "$ZEN" ]]; then
    echo "$ZEN"
    return
  fi
  if [[ -n "${DOTFILES:-}" && -d "$DOTFILES" ]]; then
    echo "$DOTFILES"
    return
  fi
  if [[ -n "${DOTFILES_DIR:-}" && -d "$DOTFILES_DIR" ]]; then
    echo "$DOTFILES_DIR"
    return
  fi
  local self_dir
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    local src_dir
    src_dir="$(dirname "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    if [[ -n "$src_dir" && -d "$src_dir" ]]; then
      self_dir="$(cd "$src_dir" 2>/dev/null && pwd 2>/dev/null || true)"
      if [[ -n "$self_dir" && -d "$self_dir/.." && -f "$self_dir/../install.sh" ]]; then
        (cd "$self_dir/.." 2>/dev/null && pwd 2>/dev/null)
        return
      fi
    fi
  fi
  local xdg_zencli="${XDG_CONFIG_HOME:-$HOME/.config}/zencli"
  if [[ -d "$xdg_zencli" ]]; then
    echo "$xdg_zencli"
    return
  fi
  local xdg_zen="${XDG_CONFIG_HOME:-$HOME/.config}/zen"
  if [[ -d "$xdg_zen" ]]; then
    echo "$xdg_zen"
    return
  fi
  local xdg_dotfiles="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
  if [[ -d "$xdg_dotfiles" ]]; then
    echo "$xdg_dotfiles"
    return
  fi
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/zencli"
}

# Backward compatibility alias for dotfiles root
_get_dotfiles_root() {
  _get_zen_root
}

# Dynamic State Directory Resolver
_get_zen_state_dir() {
  echo "${ZENCLI_STATE_DIR:-${ZEN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/zencli}}"
}

# Dynamic Temporary Cache/Log Directory Resolver
_get_zen_tmp_dir() {
  local dir="${TMPDIR:-/tmp}/zencli"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || true
  echo "$dir"
}

# Dynamic Command Log File Resolver
_get_cmdlog_path() {
  local state_dir="$(_get_zen_state_dir)"
  echo "${_CMD_LOG:-${CMD_LOG:-$state_dir/commands.log}}"
}

# Dynamic Manifest File Resolver
_get_manifest_path() {
  local root="$(_get_zen_root)"
  local candidates=(
    "${ZEN_MANIFEST:-}"
    "$root/.installed.json"
    "$(_get_zen_state_dir)/.installed.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/zencli/.installed.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/zen/.installed.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.installed.json"
  )
  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  echo "$root/.installed.json"
}

# ==============================================================================
# ZENCLI MIGRATION & REORGANIZATION ENGINE
# ==============================================================================
_zen_cmd_migrate() {
  local mode="apply"
  for arg in "$@"; do
    case "$arg" in
      --status|--check|-s)
        mode="status"
        ;;
      --dry-run|-n)
        mode="dry-run"
        ;;
      --apply|-a)
        mode="apply"
        ;;
      --silent|-q)
        mode="silent"
        ;;
      -h|--help)
        cat <<EOF
Usage: zencli migrate [OPTIONS] (or: zen migrate)

Audit and migrate legacy configurations, state files, and directories.

Options:
  --status, -s    Inspect legacy artifacts without changing anything
  --dry-run, -n   Simulate migration and cleanup steps
  --apply, -a     Execute migration and clean up legacy artifacts (default)
  --silent, -q    Run quietly without output unless an error occurs
  -h, --help      Show this help message
EOF
        return 0
        ;;
    esac
  done

  local target_state="$(_get_zen_state_dir)"
  local target_config="$(_get_zen_root)"

  # Canonical target paths (default to ~/.config/zencli and ~/.local/state/zencli)
  local canonical_config="${XDG_CONFIG_HOME:-$HOME/.config}/zencli"
  local canonical_state="${XDG_STATE_HOME:-$HOME/.local/state}/zencli"

  local dest_config="$target_config"
  if [[ "$dest_config" == "${XDG_CONFIG_HOME:-$HOME/.config}/zen" || "$dest_config" != "${XDG_CONFIG_HOME:-$HOME/.config}"/* ]]; then
    dest_config="$canonical_config"
  fi
  local dest_state="$target_state"
  if [[ "$dest_state" == "${XDG_STATE_HOME:-$HOME/.local/state}/zen" || "$dest_state" != "${XDG_STATE_HOME:-$HOME/.local/state}"/* ]]; then
    dest_state="$canonical_state"
  fi

  local pending=0

  # Check MIG-001: Legacy State Directories
  local mig_states=()
  for s in "${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles" "${XDG_STATE_HOME:-$HOME/.local/state}/zen"; do
    if [[ -d "$s" && "$s" != "$dest_state" ]]; then
      mig_states+=("$s")
      ((pending++))
    fi
  done

  # Check MIG-002: Legacy Config Directories
  local mig_configs=()
  for c in "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles" "${XDG_CONFIG_HOME:-$HOME/.config}/zen"; do
    if [[ -d "$c" && "$c" != "$dest_config" ]]; then
      mig_configs+=("$c")
      ((pending++))
    fi
  done

  # Check MIG-003: Git config reference
  local mig_git_pending=0
  if command -v git >/dev/null 2>&1 && [[ -f "$HOME/.gitconfig" ]]; then
    local current_git_includes
    current_git_includes="$(git config --global --get-all include.path 2>/dev/null || true)"
    if echo "$current_git_includes" | grep -qE '(zen|dotfiles)/\.gitconfig' && ! echo "$current_git_includes" | grep -Fxq "$dest_config/.gitconfig"; then
      mig_git_pending=1
      ((pending++))
    fi
  fi

  # Check MIG-004: Shell profile hooks
  local mig_hooks=()
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]]; then
      if grep -qE '(# Load (dotfiles|zen|Zen)\b|/(dotfiles|zen)/core|/(dotfiles|zen)/local)' "$rc" 2>/dev/null; then
        if ! grep -qE "(\"|\')$dest_config(\"|\')" "$rc" 2>/dev/null; then
          mig_hooks+=("$rc")
          ((pending++))
        fi
      fi
    fi
  done

  # Check MIG-005: Managed symlinks (e.g. ~/.tmux.conf)
  local mig_symlinks=()
  if [[ -L "$HOME/.tmux.conf" ]]; then
    local tmux_target
    tmux_target="$(readlink -f "$HOME/.tmux.conf" 2>/dev/null || true)"
    if [[ "$tmux_target" == *"/dotfiles/tmux/"* || "$tmux_target" == *"/zen/tmux/"* ]] && [[ "$tmux_target" != *"/zencli/tmux/"* ]]; then
      mig_symlinks+=("$HOME/.tmux.conf")
      ((pending++))
    fi
  fi

  if [[ "$mode" == "status" ]]; then
    echo "=== ZENCLI MIGRATION STATUS ==="
    if (( pending == 0 )); then
      echo "✔ System is clean and up to date. No pending migrations."
      return 0
    fi
    echo "Pending migrations ($pending):"
    for s in "${mig_states[@]}"; do
      echo "  • [MIG-001] Legacy state directory present: $s -> $dest_state"
    done
    for c in "${mig_configs[@]}"; do
      echo "  • [MIG-002] Legacy config directory present: $c -> $dest_config"
    done
    (( mig_git_pending )) && echo "  • [MIG-003] Legacy git config include detected in ~/.gitconfig -> $dest_config/.gitconfig"
    for h in "${mig_hooks[@]}"; do
      echo "  • [MIG-004] Legacy shell profile hook detected in: $h -> $dest_config"
    done
    for l in "${mig_symlinks[@]}"; do
      echo "  • [MIG-005] Legacy managed symlink detected: $l -> $dest_config/tmux/.tmux.conf"
    done
    echo
    echo "Run 'zencli migrate' to apply migrations and clean up legacy items."
    return 0
  fi

  if [[ "$mode" == "dry-run" ]]; then
    echo "=== ZENCLI MIGRATION SIMULATION (DRY-RUN) ==="
    if (( pending == 0 )); then
      echo "✔ Nothing to migrate."
      return 0
    fi
    for s in "${mig_states[@]}"; do
      echo "[DRY-RUN] Would create: $dest_state"
      [[ -f "$s/commands.log" ]] && echo "[DRY-RUN] Would move/merge: $s/commands.log -> $dest_state/commands.log"
      echo "[DRY-RUN] Would remove: $s"
    done
    for c in "${mig_configs[@]}"; do
      if [[ ! -d "$dest_config" ]]; then
        echo "[DRY-RUN] Would rename directory: $c -> $dest_config"
      else
        echo "[DRY-RUN] Would migrate essential configs from $c to $dest_config"
        echo "[DRY-RUN] Would remove: $c"
      fi
    done
    if (( mig_git_pending )); then
      echo "[DRY-RUN] Would update ~/.gitconfig include.path to point to $dest_config/.gitconfig"
    fi
    for h in "${mig_hooks[@]}"; do
      echo "[DRY-RUN] Would update shell hook in $h to point to $dest_config"
    done
    for l in "${mig_symlinks[@]}"; do
      echo "[DRY-RUN] Would update symlink $l -> $dest_config/tmux/.tmux.conf"
    done
    return 0
  fi

  # Apply mode (and silent mode)
  log_msg() {
    [[ "$mode" != "silent" ]] && echo "$@"
  }

  if (( pending == 0 )); then
    log_msg "✔ All configurations and state directories are up to date. Nothing to migrate."
    return 0
  fi

  log_msg "==> Applying ZenCLI migrations ($pending items)..."

  # Apply MIG-001: State Directory Migration
  if (( ${#mig_states[@]} > 0 )); then
    mkdir -p "$dest_state" 2>/dev/null || true
    for s in "${mig_states[@]}"; do
      if [[ -f "$s/commands.log" ]]; then
        if [[ ! -f "$dest_state/commands.log" ]]; then
          mv "$s/commands.log" "$dest_state/commands.log" 2>/dev/null || true
          log_msg "  ✔ Migrated commands.log to $dest_state/commands.log"
        elif [[ -s "$s/commands.log" ]]; then
          cat "$s/commands.log" >> "$dest_state/commands.log" 2>/dev/null || true
          rm -f "$s/commands.log" 2>/dev/null || true
          log_msg "  ✔ Merged legacy commands.log into $dest_state/commands.log"
        fi
      fi
      if [[ -f "$s/.installed.json" && ! -f "$dest_state/.installed.json" ]]; then
        mv "$s/.installed.json" "$dest_state/.installed.json" 2>/dev/null || true
      fi
      rm -rf "$s" 2>/dev/null || true
      log_msg "  ✔ Cleaned up legacy state directory: $s"
    done
  fi

  # Apply MIG-002: Config Directory Migration
  if (( ${#mig_configs[@]} > 0 )); then
    for c in "${mig_configs[@]}"; do
      if [[ ! -d "$dest_config" ]]; then
        mv "$c" "$dest_config" 2>/dev/null || true
        git -C "$dest_config" remote set-url origin "https://github.com/venhdev/zenforge.git" 2>/dev/null || true
        log_msg "  ✔ Renamed $c to $dest_config"
      else
        for f in "$c/.installed.json" "$c/local/local.env"; do
          if [[ -f "$f" ]]; then
            local rel="${f#"$c/"}"
            local dest="$dest_config/$rel"
            if [[ ! -f "$dest" ]]; then
              mkdir -p "$(dirname "$dest")" 2>/dev/null || true
              cp -a "$f" "$dest" 2>/dev/null || true
              log_msg "  ✔ Preserved $rel from $c"
            fi
          fi
        done
        rm -rf "$c" 2>/dev/null || true
        log_msg "  ✔ Cleaned up legacy config directory: $c"
      fi
    done
  fi

  # Apply MIG-003: Git Config Reference
  if (( mig_git_pending )); then
    git config --global --unset-all include.path 'dotfiles/\.gitconfig' 2>/dev/null || true
    git config --global --unset-all include.path 'zen/\.gitconfig' 2>/dev/null || true
    if [[ -f "$dest_config/.gitconfig" ]]; then
      if ! git config --global --get-all include.path 2>/dev/null | grep -Fxq "$dest_config/.gitconfig"; then
        git config --global --add include.path "$dest_config/.gitconfig"
      fi
    fi
    log_msg "  ✔ Updated global Git config include.path to $dest_config/.gitconfig"
  fi

  # Apply MIG-004: Shell Profile Hooks
  if (( ${#mig_hooks[@]} > 0 )); then
    for rc in "${mig_hooks[@]}"; do
      if [[ -f "$rc" ]]; then
        sed -E \
          -e "s#ZEN=\"[^\"]*/\.config/(zen|dotfiles)\"#ZENCLI=\"$dest_config\"#g" \
          -e "s#DOTFILES=\"[^\"]*/\.config/(zen|dotfiles)\"#ZENCLI=\"$dest_config\"#g" \
          -e "s#ZENCLI=\"[^\"]*/\.config/(zen|dotfiles)\"#ZENCLI=\"$dest_config\"#g" \
          -e "s#\"\\\$ZEN\"#\"\\\$ZENCLI\"#g" \
          -e "s#\"\\\$ZEN/#\"\\\$ZENCLI/#g" \
          -e "s#unset _f (DOTFILES|ZEN|ZENCLI)\b#unset _f ZENCLI#g" \
          -e "s#\"\\\$HOME/\.config/(zen|dotfiles)\"#\"$dest_config\"#g" \
          -e "s#\# Load (Zen|dotfiles|ZenCLI)#\# Load ZenCLI#g" \
          "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
        log_msg "  ✔ Updated shell profile hook in $rc to point to $dest_config"
      fi
    done
  fi

  # Apply MIG-005: Managed Symlinks
  if (( ${#mig_symlinks[@]} > 0 )); then
    for l in "${mig_symlinks[@]}"; do
      if [[ "$l" == "$HOME/.tmux.conf" && -f "$dest_config/tmux/.tmux.conf" ]]; then
        ln -sf "$dest_config/tmux/.tmux.conf" "$HOME/.tmux.conf"
        log_msg "  ✔ Relinked $l to $dest_config/tmux/.tmux.conf"
      fi
    done
  fi

  log_msg "✔ Migration completed successfully."
  return 0
}

# ==============================================================================
# ZENCLI: CANONICAL ECOSYSTEM GATEWAY & PACKAGE ORCHESTRATOR
# ==============================================================================
zencli() {
  local subcmd="${1:-}"
  local dotfiles_root="$(_get_zen_root)"

  case "$subcmd" in
    "")
      _zen_version
      echo
      _zen_help
      ;;

    tui)
      local installer="$dotfiles_root/scripts/install-tools.sh"
      if [[ -f "$installer" ]]; then
        bash "$installer"
      else
        echo "Error: Developer tools installer not found at $installer" >&2
        return 1
      fi
      ;;

    migrate)
      shift
      _zen_cmd_migrate "$@"
      ;;

    i|install)
      shift
      _zen_cmd_install "$@"
      ;;

    rm|remove|uninstall)
      shift
      _zen_cmd_remove "$@"
      ;;

    update|up)
      shift
      _zen_cmd_update "$@"
      ;;

    upgrade)
      shift
      _zen_cmd_upgrade "$@"
      ;;

    search)
      shift
      _zen_cmd_search "$@"
      ;;

    setup|init)
      shift
      local installer="$dotfiles_root/install.sh"
      if [[ -f "$installer" ]]; then
        bash "$installer" "$@"
      else
        echo "Error: Dotfiles installer not found at $installer" >&2
        return 1
      fi
      ;;

    sync)
      shift
      _zen_cmd_sync "$@"
      ;;

    doctor)
      shift
      local doctor_lib="$dotfiles_root/core/45-doctor-lib.sh"
      if [[ -f "$doctor_lib" ]]; then
        # shellcheck source=./45-doctor-lib.sh
        . "$doctor_lib"
        _zen_doctor "$@"
      else
        echo "Error: Doctor module not found at $doctor_lib" >&2
        return 1
      fi
      ;;

    ali|alias)
      shift
      local alias_lib="$dotfiles_root/core/12-alias-catalog-lib.sh"
      if [[ -f "$alias_lib" ]]; then
        # shellcheck source=./12-alias-catalog-lib.sh
        . "$alias_lib"
        _zen_alias_catalog "$@"
      else
        echo "Error: Alias catalog module not found at $alias_lib" >&2
        return 1
      fi
      ;;

    sleep)
      shift
      if declare -F sleepin >/dev/null 2>&1; then
        sleepin "$@"
      else
        local minutes="${1:-30}"
        if ! [[ "$minutes" =~ ^[0-9]+$ ]] || (( minutes < 0 )); then
          echo "Usage: zen sleep [minutes] (default: 30)" >&2
          return 1
        fi
        echo "Computer will sleep in $minutes minute(s). Press Ctrl+C to cancel."
        local psh="${DOTFILES_WIN_PATH:-$_WIN_DIR}/System32/WindowsPowerShell/v1.0/powershell.exe"
        if [[ -x "$psh" ]]; then
          "$psh" -NoProfile -Command "Start-Sleep -Seconds ($minutes * 60); Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport(\"PowrProf.dll\", SetLastError = true)] public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);'; [Win32.Power]::SetSuspendState(\$false, \$false, \$false) | Out-Null"
        elif command -v powershell.exe >/dev/null 2>&1; then
          powershell.exe -NoProfile -Command "Start-Sleep -Seconds ($minutes * 60); Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport(\"PowrProf.dll\", SetLastError = true)] public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);'; [Win32.Power]::SetSuspendState(\$false, \$false, \$false) | Out-Null"
        else
          echo "Error: Windows PowerShell not found to initiate system sleep." >&2
          return 1
        fi
      fi
      ;;

    ski)
      shift
      _zen_cmd_ski "$@"
      ;;

    skiv)
      shift
      _zen_cmd_skiv "$@"
      ;;

    skiup)
      shift
      _zen_cmd_ski update -p -y "$@"
      ;;

    --all|-a)
      local installer="$dotfiles_root/scripts/install-tools.sh"
      if [[ -f "$installer" ]]; then
        bash "$installer" --all
      else
        echo "Error: Developer tools installer not found at $installer" >&2
        return 1
      fi
      ;;

    -v|--version|version|ver)
      _zen_version
      ;;

    -h|--help|help)
      _zen_help
      ;;

    *)
      echo "❌ Unknown subcommand: '$subcmd'" >&2
      echo "Run 'zencli --help' (or 'zen --help') for available commands and usage." >&2
      return 1
      ;;
  esac
}

# ==============================================================================
# ZENFORGE INSTALLER (Production Pre-built & Local Source Build)
# ==============================================================================
_zen_install_zenforge() {
  local source_path=""
  local requested_ver=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source|-s|--src)
        source_path="$2"
        shift 2
        ;;
      --version|-v)
        requested_ver="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  zen i zenforge                      Download & install latest official pre-built binary
  zen i zenforge --version <v>        Install specific GitHub release version
  zen i zenforge --source <path>      Verify requirements, build from source & install

Options:
  -s, --source <path>   Path to local zenforge repository (contains apps/daemon)
  -v, --version <v>     Specific version tag to download (e.g. 0.2.1)
EOF
        return 0
        ;;
      *)
        echo "❌ Unknown option for zenforge installer: '$1'" >&2
        echo "Run 'zen i zenforge --help' for usage." >&2
        return 1
        ;;
    esac
  done

  # ----------------------------------------------------------------------------
  # Chế độ 1: Build từ Local Source Path (Explicit Developer Mode)
  # ----------------------------------------------------------------------------
  if [[ -n "$source_path" ]]; then
    # Normalize absolute path
    if [[ ! -d "$source_path" ]]; then
      echo "❌ Error: Specified source directory does not exist: $source_path" >&2
      return 1
    fi
    local abs_src
    abs_src="$(cd "$source_path" && pwd -P)"

    local daemon_dir="$abs_src/apps/daemon"
    local web_dir="$abs_src/apps/web"

    if [[ ! -d "$daemon_dir" || ! -f "$daemon_dir/go.mod" ]]; then
      echo "❌ Error: '$abs_src' is not a valid ZenForge repository." >&2
      echo "   Missing required directory: apps/daemon/ with go.mod" >&2
      return 1
    fi

    # Preflight Check Toolchains
    local missing=()
    command -v go >/dev/null 2>&1 || missing+=("go (>= 1.24)")
    command -v make >/dev/null 2>&1 || missing+=("make")
    if ! command -v pnpm >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
      missing+=("pnpm or npm")
    fi

    local go_ver="not found"
    if command -v go >/dev/null 2>&1; then
      go_ver="$(go version 2>/dev/null | awk '{print $3}')"
    fi

    local node_pkg_mgr="none"
    if command -v pnpm >/dev/null 2>&1; then
      node_pkg_mgr="pnpm ($(pnpm --version 2>/dev/null))"
    elif command -v npm >/dev/null 2>&1; then
      node_pkg_mgr="npm ($(npm --version 2>/dev/null))"
    fi

    echo "────────────────────────────────────────────────────────────────────────"
    echo " [ZENFORGE LOCAL SOURCE BUILD AUDIT]"
    echo " • Source Path  : $abs_src"
    echo " • Daemon Mod   : $daemon_dir"
    echo " • Go Toolchain : $go_ver"
    echo " • Web Manager  : $node_pkg_mgr"
    echo " • Target Path  : $HOME/.local/bin/zenfd"
    echo "────────────────────────────────────────────────────────────────────────"

    if ((${#missing[@]} > 0)); then
      echo "❌ Preflight failed! Missing required build toolchain(s):" >&2
      for m in "${missing[@]}"; do
        echo "   - $m" >&2
      done
      echo "💡 Please install missing tools before building from source." >&2
      return 1
    fi

    local confirm=""
    if [[ -t 0 ]]; then
      read -r -p "Proceed to build and install zenfd to ~/.local/bin? [y/N]: " confirm
    else
      read -r confirm || confirm="n"
    fi
    case "$confirm" in
      [yY]|[yY][eE][sS]) ;;
      *)
        echo "[-] Build canceled by user."
        return 0
        ;;
    esac

    echo "==> Building ZenForge single-binary control plane (daemon + embedded web)..."
    if (cd "$daemon_dir" && make build); then
      local bin_src="$daemon_dir/bin/zenfd"
      if [[ -f "$bin_src" ]]; then
        mkdir -p "$HOME/.local/bin"
        install -m 755 "$bin_src" "$HOME/.local/bin/zenfd"
        echo "  ✔ Successfully installed: $HOME/.local/bin/zenfd"
        "$HOME/.local/bin/zenfd" --version 2>/dev/null || true
        return 0
      else
        echo "❌ Build artifact $bin_src not found." >&2
        return 1
      fi
    else
      echo "❌ Build failed inside $daemon_dir." >&2
      return 1
    fi
  fi

  # ----------------------------------------------------------------------------
  # Chế độ 2: Tải Pre-built Binary từ GitHub Release (Production Zero-Build)
  # ----------------------------------------------------------------------------
  local repo="venhdev/zenforge"
  local os_type
  case "$(uname -s 2>/dev/null)" in
    Linux*)   os_type="linux" ;;
    Darwin*)  os_type="darwin" ;;
    MINGW*|MSYS*|CYGWIN*) os_type="windows" ;;
    *)        os_type="linux" ;;
  esac

  local arch_type
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)   arch_type="amd64" ;;
    aarch64|arm64)  arch_type="arm64" ;;
    *)              arch_type="amd64" ;;
  esac

  echo "==> Resolving ZenForge release from GitHub (${repo})..."
  local ver="$requested_ver"
  if [[ -z "$ver" ]]; then
    ver="$(curl -s --connect-timeout 4 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | grep -Po '"tag_name":\s*"\K[^"]*' || true)"
    if [[ -z "$ver" ]]; then
      local redirect_url
      redirect_url="$(curl -sI --connect-timeout 4 "https://github.com/${repo}/releases/latest" 2>/dev/null | grep -i '^location:' | awk '{print $2}' | tr -d '\r\n' || true)"
      if [[ "$redirect_url" =~ /tag/([^/]+)$ ]]; then
        ver="${BASH_REMATCH[1]}"
      fi
    fi
  fi

  ver="${ver#v}"
  if [[ -z "$ver" || "$ver" == "unknown" ]]; then
    echo "❌ Error: Unable to resolve latest release version from https://github.com/${repo}/releases." >&2
    return 1
  fi

  local ext="tar.gz"
  [[ "$os_type" == "windows" ]] && ext="zip"
  local asset_name="zenfd_${ver}_${os_type}_${arch_type}.${ext}"
  local download_url="https://github.com/${repo}/releases/download/v${ver}/${asset_name}"

  echo "────────────────────────────────────────────────────────────────────────"
  echo " [ZENFORGE OFFICIAL PRE-BUILT BINARY]"
  echo " • Repository   : https://github.com/${repo}"
  echo " • Version      : v${ver}"
  echo " • Platform     : ${os_type}/${arch_type}"
  echo " • Asset        : ${asset_name}"
  echo " • Target Path  : $HOME/.local/bin/zenfd (Zero-build)"
  echo "────────────────────────────────────────────────────────────────────────"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  echo "==> Downloading ${download_url}..."
  if ! curl -sL --fail "$download_url" -o "$tmp_dir/$asset_name"; then
    echo "❌ Download failed for ${download_url}" >&2
    rm -rf "$tmp_dir"
    return 1
  fi

  echo "==> Extracting and installing to $HOME/.local/bin/zenfd..."
  if [[ "$ext" == "tar.gz" ]]; then
    tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir"
  else
    unzip -q "$tmp_dir/$asset_name" -d "$tmp_dir"
  fi

  local extracted_bin="$tmp_dir/zenfd"
  [[ "$os_type" == "windows" && -f "$tmp_dir/zenfd.exe" ]] && extracted_bin="$tmp_dir/zenfd.exe"

  if [[ ! -f "$extracted_bin" ]]; then
    extracted_bin="$(find "$tmp_dir" -type f -name "zenfd*" ! -name "*.tar.gz" ! -name "*.zip" | head -n 1)"
  fi

  if [[ -f "$extracted_bin" ]]; then
    mkdir -p "$HOME/.local/bin"
    install -m 755 "$extracted_bin" "$HOME/.local/bin/zenfd"
    rm -rf "$tmp_dir"
    echo "  ✔ Successfully installed: $HOME/.local/bin/zenfd"
    "$HOME/.local/bin/zenfd" --version 2>/dev/null || true
    echo "✅ ZenForge (zenfd) is ready to use."
    return 0
  else
    echo "❌ Could not find extracted binary in release package." >&2
    rm -rf "$tmp_dir"
    return 1
  fi
}

# zen: Terminal shorthand alias/wrapper for zencli
zen() {
  zencli "$@"
}

_zen_cmd_install() {
  if [[ $# -eq 0 ]]; then
    echo "❌ Error: Missing package name or option." >&2
    echo
    echo "Usage:" >&2
    echo "  zen i <pkg...>                     Install system package(s) or managed tool(s)" >&2
    echo "  zen i zenforge                     Install official pre-built zenfd to ~/.local/bin" >&2
    echo "  zen i zenforge --source <path>     Audit requirements, build from source & install" >&2
    echo "  zen i --all                        Batch install all missing managed tools" >&2
    return 1
  fi

  if [[ "$1" == "--all" || "$1" == "-a" ]]; then
    local installer="$(_get_dotfiles_root)/scripts/install-tools.sh"
    bash "$installer" --all
    return $?
  fi

  if [[ "$1" == "zenforge" || "$1" == "zenfd" ]]; then
    shift
    _zen_install_zenforge "$@"
    return $?
  fi

  _zen_package_action "install" "$@"
}

_zen_cmd_remove() {
  if [[ $# -eq 0 ]]; then
    echo "❌ Error: Missing package name to remove." >&2
    echo
    echo "Usage:" >&2
    echo "  zen rm <pkg...>      Uninstall package(s)" >&2
    return 1
  fi
  _zen_package_action "remove" "$@"
}

_zen_cmd_update() {
  local check_all=0
  if [[ "${1:-}" == "--all" || "${1:-}" == "-a" ]]; then
    check_all=1
  fi

  echo "==> Updating package repository indexes..."
  _zen_package_action "update"

  if (( check_all )); then
    echo
    echo "==> Tracking managed developer tools..."
    local manifest_file="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.installed.json"
    if [[ -f "$manifest_file" ]] && command -v python3 >/dev/null 2>&1; then
      python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    tools = data.get("tools", {})
    if tools:
        print(f"Tracking {len(tools)} managed tools in .installed.json:")
        for k, v in sorted(tools.items()):
            print(f"  • {k:10s} (v{v.get(\"installed_version\", \"?\")}) origin: {v.get(\"origin\", \"?\")}")
except Exception:
    pass
' "$manifest_file" 2>/dev/null || true
    fi
  fi
}

_zen_cmd_upgrade() {
  if [[ $# -eq 0 ]]; then
    echo "⚠️  Notice: 'zen upgrade' requires an explicit target to prevent unintended system-wide modifications." >&2
    echo
    echo "Usage:" >&2
    echo "  zen upgrade --all       Upgrade system packages AND managed developer tools" >&2
    echo "  zen upgrade system      Upgrade system packages only (apt/brew/pacman/winget)" >&2
    echo "  zen upgrade <pkg...>    Upgrade/reinstall specific package(s)" >&2
    return 1
  fi

  case "$1" in
    --all|-a)
      echo "==> Upgrading system packages..."
      _zen_package_action "upgrade"
      echo
      echo "==> Updating managed developer tools..."
      local installer="$(_get_dotfiles_root)/scripts/install-tools.sh"
      bash "$installer" --all
      ;;
    system)
      echo "==> Upgrading system packages..."
      _zen_package_action "upgrade"
      ;;
    *)
      _zen_package_action "install" "$@"
      ;;
  esac
}

_zen_cmd_search() {
  if [[ $# -eq 0 ]]; then
    echo "❌ Error: Missing search query." >&2
    echo "Usage: zen search <query>" >&2
    return 1
  fi
  _zen_package_action "search" "$@"
}

_zen_ski_help() {
  cat <<'EOF'
zen ski - Agent Skills Orchestrator (powered by Vercel Skills CLI)

Usage:
  zen ski <source> [options]         Add skill(s) from GitHub, URL, or local path
  zen skiv [options]                 Personal skills (venhdev/zenforge, default: .agents/skills)
  zen skiup                          Update project skills according to lockfile (-p -y)

Common Management:
  zen ski update [skills...]         Update installed skills to latest versions
  zen ski rm <skill...>              Remove installed agent skill(s)
  zen ski ls [-g]                    List installed skills (project or global -g)
  zen ski find [query]               Search agent skills interactively
  zen ski check                      Check for available skill updates

Add Options:
  -g, --global                       Install to user directory (~/<agent>/skills)
  -a, --agent <agents...>            Target specific agent(s) (default for skiv: codex)
  -s, --skill <skills...>            Specify skill names to install
  -l, --list                         List available skills in source without installing
  -y, --yes                          Skip confirmation prompts
  --copy                             Copy files instead of symlinking

Examples:
  zen skiv                           Interactive selection into .agents/skills/
  zen skiv -y                        Install all personal skills to .agents/skills/
  zen skiv -s clarify                Install specific skill to .agents/skills/
  zen skiv -a claude-code            Install to Claude Code instead of default
  zen skiup                          Update all installed project skills
  zen ski vercel-labs/agent-skills   Install external skills
EOF
}

_zen_cmd_skiv() {
  local has_agent=0
  for arg in "$@"; do
    if [[ "$arg" == "-a" || "$arg" == "--agent" || "$arg" == --agent=* ]]; then
      has_agent=1
      break
    fi
  done

  if [[ $has_agent -eq 0 ]]; then
    _zen_cmd_ski "venhdev/zenforge" -a codex "$@"
  else
    _zen_cmd_ski "venhdev/zenforge" "$@"
  fi
}

_zen_cmd_ski() {
  if ! command -v npx >/dev/null 2>&1; then
    echo "❌ Error: 'npx' is required to manage agent skills." >&2
    echo "💡 Run 'zen i node' (or install Node.js) to enable skills management." >&2
    return 1
  fi

  if [[ $# -eq 0 ]]; then
    _zen_ski_help
    return 0
  fi

  local action="${1:-}"
  case "$action" in
    -h|--help|help)
      _zen_ski_help
      ;;
    rm|remove)
      shift
      npx --yes skills remove "$@"
      ;;
    ls|list)
      shift
      npx --yes skills list "$@"
      ;;
    update|up|upgrade)
      shift
      npx --yes skills update "$@"
      ;;
    find)
      shift
      npx --yes skills find "$@"
      ;;
    check)
      shift
      npx --yes skills check "$@"
      ;;
    init)
      shift
      npx --yes skills init "$@"
      ;;
    add)
      shift
      npx --yes skills add "$@"
      ;;
    v|venh)
      shift
      _zen_cmd_skiv "$@"
      ;;
    *)
      npx --yes skills add "$@"
      ;;
  esac
}

_zen_timer_start() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    echo "$EPOCHREALTIME"
    return
  fi
  local nano
  nano="$(date +%s%N 2>/dev/null || true)"
  if [[ "$nano" =~ ^[0-9]{11,}$ ]]; then
    echo "${nano:0:10}.${nano:10:6}"
    return
  fi
  date +%s
}

_zen_timer_elapsed() {
  local start="${1:-0}"
  local end
  end="$(_zen_timer_start)"
  awk -v s="$start" -v e="$end" 'BEGIN {
    diff = e - s;
    if (diff < 0) diff = 0;
    if (diff < 1) {
      printf "%dms", int(diff * 1000);
    } else if (diff < 60) {
      printf "%.2fs", diff;
    } else {
      m = int(diff / 60);
      printf "%dm %.1fs", m, diff - (m * 60);
    }
  }'
}

_zen_cmd_sync() {
  local dotfiles_root="$(_get_dotfiles_root)"

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: zen sync [OPTIONS]"
    echo
    echo "Pull latest commits from remote and reload aliases without running setup."
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo
    echo "Note: To reconfigure system modules or run full provisioning, use 'zen setup'."
    return 0
  fi

  local t0
  t0="$(_zen_timer_start)"

  echo "==> Syncing ZenCLI Ecosystem ($dotfiles_root)..."

  # 1. Pull latest commits quietly
  if [[ -d "$dotfiles_root/.git" ]]; then
    if command -v git >/dev/null 2>&1; then
      local old_head new_head git_out pull_status=0
      old_head="$(git -C "$dotfiles_root" rev-parse --short HEAD 2>/dev/null || true)"
      git_out="$(git -C "$dotfiles_root" pull --rebase --autostash --quiet 2>&1)" || pull_status=$?
      new_head="$(git -C "$dotfiles_root" rev-parse --short HEAD 2>/dev/null || true)"

      if (( pull_status != 0 )); then
        echo "  ✖ Git pull failed:" >&2
        [[ -n "$git_out" ]] && echo "$git_out" >&2
      elif [[ "$old_head" != "$new_head" ]]; then
        echo "  ✔ Pulled $new_head"
      else
        echo "  ✔ Repository up to date ($new_head)"
      fi
    else
      echo "  ✖ git command not found; skipping repository pull." >&2
    fi
  else
    echo "  ℹ '$dotfiles_root' is not a git repository; skipping pull."
  fi

  # 2. Automated migration & legacy cleanup
  _zen_cmd_migrate --silent 2>/dev/null || true

  # 3. Synchronize git include.path
  if command -v git >/dev/null 2>&1 && [[ -f "$dotfiles_root/.gitconfig" ]]; then
    if ! git config --global --get-all include.path 2>/dev/null | grep -Fxq "$dotfiles_root/.gitconfig"; then
      git config --global --add include.path "$dotfiles_root/.gitconfig"
    fi
  fi

  # 3. Source local env if present
  if [[ -r "$dotfiles_root/local/local.env" ]]; then
    # shellcheck source=/dev/null
    . "$dotfiles_root/local/local.env"
  fi

  # 4. Reload shell core aliases
  shopt -s expand_aliases 2>/dev/null || true
  local alias_count=0
  if [[ -f "$dotfiles_root/core/10-base-aliases.sh" ]]; then
    # shellcheck source=/dev/null
    . "$dotfiles_root/core/10-base-aliases.sh"
    alias_count=$(grep -cE '^[[:space:]]*alias ' "$dotfiles_root/core/10-base-aliases.sh" 2>/dev/null || echo 0)
  fi

  # 5. Reload enabled modules
  local mod_count=0
  if [[ -d "$dotfiles_root/enabled.d" ]]; then
    for _mod in "$dotfiles_root"/enabled.d/*.sh; do
      if [[ -r "$_mod" ]]; then
        # shellcheck source=/dev/null
        . "$_mod"
        ((mod_count++))
      fi
    done
  fi

  # 6. Reload platform library and alias catalog
  if [[ -f "$dotfiles_root/core/00-platform-lib.sh" ]]; then
    # shellcheck source=/dev/null
    . "$dotfiles_root/core/00-platform-lib.sh"
  fi
  if [[ -f "$dotfiles_root/core/12-alias-catalog-lib.sh" ]]; then
    # shellcheck source=/dev/null
    . "$dotfiles_root/core/12-alias-catalog-lib.sh"
  fi

  echo "  ✔ Refreshed session ($alias_count aliases, $mod_count modules)"
  printf "✔ Done in %s\n" "$(_zen_timer_elapsed "$t0")"
}

_zen_package_action() {
  local action="$1"
  shift

  local mgr=""
  if command -v brew &>/dev/null; then
    mgr="brew"
  elif command -v apt-get &>/dev/null; then
    mgr="apt"
  elif command -v pacman &>/dev/null; then
    mgr="pacman"
  elif command -v dnf &>/dev/null; then
    mgr="dnf"
  elif command -v winget.exe &>/dev/null; then
    mgr="winget"
  elif command -v scoop &>/dev/null; then
    mgr="scoop"
  fi

  if [[ -z "$mgr" ]]; then
    echo "❌ No supported package manager found (brew, apt, pacman, dnf, winget, scoop)" >&2
    return 1
  fi

  case "$action" in
    update)
      case "$mgr" in
        brew)   brew update ;;
        apt)    sudo apt update ;;
        pacman) sudo pacman -Sy ;;
        dnf)    sudo dnf check-update ;;
        winget) winget.exe source update ;;
        scoop)  scoop update ;;
      esac
      ;;
    upgrade)
      case "$mgr" in
        brew)   brew upgrade ;;
        apt)    sudo apt update && sudo apt upgrade -y ;;
        pacman) sudo pacman -Syu ;;
        dnf)    sudo dnf upgrade -y ;;
        winget) winget.exe upgrade --all ;;
        scoop)  scoop update * ;;
      esac
      ;;
    install|add)
      case "$mgr" in
        brew)   brew install "$@" ;;
        apt)    sudo apt install "$@" ;;
        pacman) sudo pacman -S "$@" ;;
        dnf)    sudo dnf install "$@" ;;
        winget) winget.exe install "$@" ;;
        scoop)  scoop install "$@" ;;
      esac
      ;;
    remove|uninstall)
      case "$mgr" in
        brew)   brew uninstall "$@" ;;
        apt)    sudo apt remove "$@" ;;
        pacman) sudo pacman -R "$@" ;;
        dnf)    sudo dnf remove "$@" ;;
        winget) winget.exe uninstall "$@" ;;
        scoop)  scoop uninstall "$@" ;;
      esac
      ;;
    search)
      case "$mgr" in
        brew)   brew search "$@" ;;
        apt)    apt search "$@" ;;
        pacman) pacman -Ss "$@" ;;
        dnf)    dnf search "$@" ;;
        winget) winget.exe search "$@" ;;
        scoop)  scoop search "$@" ;;
      esac
      ;;
  esac
}

_zen_version() {
  local dotfiles_root="$(_get_zen_root)"
  local ver="v1.3.0"
  local commit_sha="-"
  local commit_date="-"
  if command -v git >/dev/null 2>&1 && [[ -d "$dotfiles_root/.git" ]]; then
    commit_sha="$(git -C "$dotfiles_root" rev-parse --short HEAD 2>/dev/null || echo "-")"
    commit_date="$(git -C "$dotfiles_root" log -1 --format="%cd" --date=short 2>/dev/null || echo "-")"
  fi

  local distro="Linux"
  if [[ -f /etc/os-release ]]; then
    distro="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "Linux")"
  elif is_darwin; then
    distro="macOS $(sw_vers -productVersion 2>/dev/null || echo "")"
  fi

  local plat="Native POSIX"
  if is_wsl; then
    plat="WSL"
  elif is_msys; then
    plat="MSYS/Windows"
  elif is_darwin; then
    plat="macOS"
  fi

  if [[ -z "${TZ:-}" && -r "$dotfiles_root/local/local.env" ]]; then
    # shellcheck disable=SC1090
    . "$dotfiles_root/local/local.env"
  fi

  local tz_id="${TZ:-}"
  if [[ -z "$tz_id" && -f /etc/timezone ]]; then
    tz_id="$(head -n 1 /etc/timezone | tr -d "[:space:]")"
  fi
  if [[ -z "$tz_id" && -L /etc/localtime ]]; then
    tz_id="$(readlink /etc/localtime | sed -E "s|.*/zoneinfo/||")"
  fi
  local tz_abbr
  tz_abbr="$(date +"%Z" 2>/dev/null || echo "UTC")"
  local tz_offset
  tz_offset="$(date +"%:z" 2>/dev/null || echo "+00:00")"
  tz_id="${tz_id:-System ($tz_abbr)}"

  printf "ZenCLI %s\n" "$ver"
  printf "Commit     : %s (%s)\n" "$commit_sha" "$commit_date"
  printf "Root       : %s\n" "$dotfiles_root"
  printf "Platform   : %s [%s]\n" "$distro" "$plat"
  printf "Timezone   : %s (%s, UTC%s)\n" "$tz_id" "$tz_abbr" "$tz_offset"
}

_zen_help() {
  local mgr=""
  if command -v brew &>/dev/null; then
    mgr="brew"
  elif command -v apt-get &>/dev/null; then
    mgr="apt"
  elif command -v pacman &>/dev/null; then
    mgr="pacman"
  elif command -v dnf &>/dev/null; then
    mgr="dnf"
  elif command -v winget.exe &>/dev/null; then
    mgr="winget"
  elif command -v scoop &>/dev/null; then
    mgr="scoop"
  fi

  cat <<EOF
ZenCLI - Unified Ecosystem Gateway & Developer Tool Orchestrator

Usage:
  zencli [subcommand] [arguments...]
  zen    [subcommand] [arguments...] (terminal shorthand)

Core & Help:
  zencli                   Show version summary and quick command helper
  zencli -v, --version     Show version and environment details
  zencli -h, --help        Show this help message
  zencli migrate [opts]    Audit and migrate legacy configurations/state

Developer Tools TUI:
  zencli tui               Launch interactive Developer Tools TUI

Headless Package Management:
  zencli i <pkg...>        Install system package(s) or managed tool(s)
  zencli i --all           Batch install missing managed dev tools
  zencli rm <pkg...>       Uninstall package(s)
  zencli update [--all]    Refresh package index indexes (--all includes tool metadata)
  zencli upgrade --all     Upgrade system packages AND managed developer tools
  zencli upgrade system    Upgrade system package manager only
  zencli upgrade <pkg...>  Upgrade or reinstall specific package(s)
  zencli search <query>    Search for packages in repository

Agent Skills Management:
  zencli ski [source|cmd]  Agent skills orchestrator (add, rm, ls, update, find)
  zencli skiv [options]    Personal skills (venhdev/zenforge, default: .agents/skills)
  zencli skiup             Update project skills according to lockfile (-p -y)

Ecosystem & Workstation:
  zencli doctor            Audit ecosystem health (OS, symlinks, git, hooks, tools)
  zencli ali [list|query]  Directory & search for all ZenCLI shortcuts and aliases
  zencli setup [mods...]   Run ZenCLI modular configuration and setup
  zencli sync              Pull latest git commits and reload newest aliases
  zencli sleep [minutes]   Put Windows machine to sleep after countdown (default: 30)

Active system manager: ${mgr:-none}
EOF
}

# Shell-aware reload helper (supports both Bash and Zsh)
unalias rel 2>/dev/null || true
rel() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    local zsh_rc="${ZDOTDIR:-$HOME}/.zshrc"
    if [[ -r "$zsh_rc" ]]; then
      # shellcheck disable=SC1090
      source "$zsh_rc"
      echo "✓ Reloaded $zsh_rc"
      return 0
    fi
  fi

  local bash_rc="$HOME/.bashrc"
  if [[ -r "$bash_rc" ]]; then
    # shellcheck disable=SC1090
    source "$bash_rc"
    echo "✓ Reloaded $bash_rc"
    return 0
  fi

  echo "❌ Neither ~/.zshrc nor ~/.bashrc found to reload." >&2
  return 1
}
