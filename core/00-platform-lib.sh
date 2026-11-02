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

# Self-locating Dotfiles Root Resolver
_get_dotfiles_root() {
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
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
  if [[ -n "$self_dir" && -d "$self_dir/.." && -f "$self_dir/../install.sh" ]]; then
    (cd "$self_dir/.." && pwd)
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
  echo "$HOME/.config/zen"
}

# zen: Unified Ecosystem Gateway, Package Manager & Tools Orchestrator
zen() {
  local subcmd="${1:-}"
  local dotfiles_root="$(_get_dotfiles_root)"

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
        echo "Error: Developer tools notebook installer not found at $installer" >&2
        return 1
      fi
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
        echo "Error: Developer tools notebook installer not found at $installer" >&2
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
      echo "Run 'zen --help' for available commands and usage." >&2
      return 1
      ;;
  esac
}

_zen_cmd_install() {
  if [[ $# -eq 0 ]]; then
    echo "❌ Error: Missing package name or option." >&2
    echo
    echo "Usage:" >&2
    echo "  zen i <pkg...>       Install system package(s) or managed tool(s)" >&2
    echo "  zen i --all          Batch install all missing managed tools" >&2
    return 1
  fi

  if [[ "$1" == "--all" || "$1" == "-a" ]]; then
    local installer="$(_get_dotfiles_root)/scripts/install-tools.sh"
    bash "$installer" --all
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
  zen skiv [options]                 Personal skills (venhdev/skills, default: .agents/skills)
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
    _zen_cmd_ski "venhdev/skills" -a codex "$@"
  else
    _zen_cmd_ski "venhdev/skills" "$@"
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

  # 2. Synchronize git include.path
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
  local dotfiles_root="$(_get_dotfiles_root)"
  local ver="v1.2.0"
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
  zen [subcommand] [arguments...]

Core & Help:
  zen                      Show version summary and quick command helper
  zen -v, --version        Show version and environment details
  zen -h, --help           Show this help message

TUI & Tools Notebook:
  zen tui                  Launch interactive Developer Tools Notebook TUI

Headless Package Management:
  zen i <pkg...>           Install system package(s) or managed tool(s)
  zen i --all              Batch install missing managed dev tools
  zen rm <pkg...>          Uninstall package(s)
  zen update [--all]       Refresh package index indexes (--all includes tool metadata)
  zen upgrade --all        Upgrade system packages AND managed developer tools
  zen upgrade system       Upgrade system package manager only
  zen upgrade <pkg...>     Upgrade or reinstall specific package(s)
  zen search <query>       Search for packages in repository

Agent Skills Management:
  zen ski [source|cmd]     Agent skills orchestrator (add, rm, ls, update, find)
  zen skiv [options]       Personal skills (venhdev/skills, default: .agents/skills)
  zen skiup                Update project skills according to lockfile (-p -y)

Ecosystem & Workstation:
  zen doctor               Audit ecosystem health (OS, symlinks, git, hooks, tools)
  zen ali [list|query]     Directory & search for all dotfiles shortcuts and aliases
  zen setup [modules...]   Run dotfiles modular configuration and setup (replaces insdf)
  zen sync                 Pull latest git commits and reload newest aliases
  zen sleep [minutes]      Put Windows machine to sleep after countdown (default: 30)

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
