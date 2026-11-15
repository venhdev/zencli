# Base system, navigation, dev, and package management aliases

# ENVIRONMENT & RELOAD
alias rebash='exec bash'
alias rezsh='exec zsh'
alias insdf='zen setup' # Dotfiles modular setup & provisioning
alias ins='zen i'       # Fast shorthand for zen install
alias ts='date +%s'

# CLIPBOARD UTILS
alias c2fn='c2f -n'     # Save clipboard to temp file only (no path copy)

# PYTHON VENV
alias va='source .venv/bin/activate'
alias vd='deactivate'

# SYSTEM CONTROL & JOURNAL
if command -v systemctl &>/dev/null; then
  alias sc='systemctl'                     # Control systemd system and service manager
  alias scu='systemctl --user'             # Control user-level systemd services
  alias scr='sudo systemctl restart'       # Restart a systemd service
  alias scs='systemctl status'             # View detailed status of a service
  alias sce='sudo systemctl enable --now'  # Enable and immediately start service
  alias scd='sudo systemctl disable --now' # Disable and immediately stop service
  alias scdr='sudo systemctl daemon-reload' # Reload systemd manager configuration
  alias scedit='sudo systemctl edit --full' # Edit service unit configuration

  alias jc='journalctl'                    # Query and display systemd journal logs
  alias jcs='journalctl -u'                # View journal logs for a specific unit
  alias jcf='journalctl -f -u'             # Follow live journal logs for a unit
fi

# SECURITY & NETWORK CHECK
alias curlip='curl ifconfig.me' # Quick check of public IP
alias ports_listen='sudo lsof -i -P -n | grep LISTEN' # Check what's hogging ports

# ENVIRONMENT VARIABLES INSPECTION
gete() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    printenv | sort
    return 0
  fi

  local val
  if val="$(printenv "$key" 2>/dev/null)"; then
    printf "%s=%s\n" "$key" "$val"
  else
    echo "⚠️  Environment variable '$key' not found." >&2
    return 1
  fi
}

# PACKAGE MANAGEMENT ALIASES
if command -v apt-get &>/dev/null; then
  alias aupdate='sudo apt update'                         # Fetch latest APT package lists
  alias aupgrade='sudo apt update && sudo apt upgrade -y' # Upgrade all installed system packages
  alias ainstall='sudo apt install'                       # Install package via APT
  alias aremove='sudo apt remove'                         # Remove package via APT
  alias asearch='apt search'                              # Search package archive
  alias afix='sudo apt --fix-broken install'              # Fix broken package dependencies
  aautoremove() {
    sudo apt autoremove --dry-run
    _run_confirm sudo apt autoremove
  }
else
  alias aupdate='zen update'                              # Update package index lists
  alias aupgrade='zen upgrade'                            # Upgrade system packages
  alias ainstall='zen i'                                  # Universal package install
  alias aremove='zen rm'                                  # Universal package remove
  alias asearch='zen search'                              # Search universal packages
fi

# PROCESS & SYSTEM MONITORING
alias pg='ps aux | grep' # Filter process table by pattern
psmem() {
  local count="${1:-15}"
  [[ "$count" =~ ^[0-9]+$ ]] || count=15
  ps -eo pid,ppid,rss,%mem,cmd --sort=-rss | head -n "$((count + 1))"
}
pscpu() {
  local count="${1:-15}"
  [[ "$count" =~ ^[0-9]+$ ]] || count=15
  ps -eo pid,ppid,%cpu,%mem,cmd --sort=-%cpu | head -n "$((count + 1))"
}

# FILE & SYSTEM & NAVIGATION
alias ..='cd ..'       # Navigate up one directory level
alias ...='cd ../..'   # Navigate up two directory levels
alias ll='ls -haltF'   # Long listing with hidden files and human sizes
alias la='ls -A'       # List almost all files (excludes . and ..)
alias l='ls -CF'       # Compact column list with classification markers
alias lsize='ls -lSrh' # Sort by size ascending (largest at bottom)

# DIRECTORY DISK USAGE
unalias ds 2>/dev/null || true
unalias dus 2>/dev/null || true
unalias dirsize 2>/dev/null || true
dirsize() {
  local target="."
  local limit=""

  case $# in
    0)
      target="."
      limit=""
      ;;
    1)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        limit="$1"
        target="."
      else
        target="$1"
        limit=""
      fi
      ;;
    *)
      if [[ "$2" =~ ^[0-9]+$ ]]; then
        target="$1"
        limit="$2"
      elif [[ "$1" =~ ^[0-9]+$ ]]; then
        limit="$1"
        target="$2"
      else
        target="$1"
        limit=""
      fi
      ;;
  esac

  if [[ ! -d "$target" ]]; then
    echo "❌ Directory not found: $target" >&2
    return 1
  fi

  local clean_target="${target%/}"
  [[ -z "$clean_target" ]] && clean_target="/"

  local cmd
  if du -d 1 -k /dev/null &>/dev/null; then
    cmd="du -d 1 -k \"$target\" 2>/dev/null"
  else
    cmd="du -k --max-depth=1 \"$target\" 2>/dev/null"
  fi

  local raw_output
  raw_output="$(eval "$cmd" | grep -v -E "[[:space:]]+(\./?|${clean_target})$" | sort -nr)"

  if [[ -z "$raw_output" ]]; then
    echo "No subdirectories found in '$target'."
    return 0
  fi

  local awk_script='
  function human(k) {
    if (k >= 1048576) return sprintf("%.2f GB", k / 1048576);
    if (k >= 1024) return sprintf("%.2f MB", k / 1024);
    return sprintf("%d KB", k);
  }
  BEGIN {
    printf "%-12s %s\n", "SIZE", "DIRECTORY";
    printf "%-12s %s\n", "----", "---------";
  }
  {
    kb = $1;
    $1 = "";
    sub(/^[[:space:]]+/, "");
    printf "%-12s %s\n", human(kb), $0;
  }
  '

  if [[ -n "$limit" ]]; then
    printf "%s\n" "$raw_output" | head -n "$limit" | awk "$awk_script"
  else
    printf "%s\n" "$raw_output" | awk "$awk_script"
  fi
}
alias dus='dirsize' # Human-readable directory disk usage sorted by size
alias ds='dirsize'  # Compact alias for dirsize

# HISTORY SEARCH
unalias h 2>/dev/null || true
unalias hs 2>/dev/null || true
h() {
  local query=""
  local limit=10

  case $# in
    0)
      query=""
      limit=10
      ;;
    1)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        limit="$1"
        query=""
      else
        query="$1"
        limit=10
      fi
      ;;
    *)
      local last="${!#}"
      if [[ "$last" =~ ^[0-9]+$ ]]; then
        limit="$last"
        query="${*:1:$#-1}"
      elif [[ "$1" =~ ^[0-9]+$ ]]; then
        limit="$1"
        query="${*:2}"
      else
        query="$*"
        limit=10
      fi
      ;;
  esac

  ((limit <= 0)) && limit=10

  if ! builtin history &>/dev/null || [[ $(builtin history | wc -l) -eq 0 ]]; then
    set -o history 2>/dev/null || true
    [[ -f "${HISTFILE:-$HOME/.bash_history}" ]] && history -r "${HISTFILE:-$HOME/.bash_history}" 2>/dev/null || true
  fi

  if [[ -n "${ZSH_VERSION:-}" ]]; then
    if [[ -n "$query" ]]; then
      fc -l -n 1 2>/dev/null | grep -i -F -- "$query" | grep -v -E '^[[:space:]]*h([[:space:]]|$)' | tail -n "$limit" | awk '{printf " \033[0;90m%2d)\033[0m %s\n", NR, $0}'
    else
      fc -l -n 1 2>/dev/null | grep -v -E '^[[:space:]]*h([[:space:]]|$)' | tail -n "$limit" | awk '{printf " \033[0;90m%2d)\033[0m %s\n", NR, $0}'
    fi
  else
    HISTTIMEFORMAT="" history | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' | \
      grep -v -E '^[[:space:]]*h([[:space:]]|$)' | \
      if [[ -n "$query" ]]; then grep -i -F -- "$query"; else cat; fi | \
      tail -n "$limit" | awk '{printf " \033[0;90m%2d)\033[0m %s\n", NR, $0}'
  fi
}
alias hs='h' # History search with limit

# FILE & SYSTEM UTILITIES
alias cls='clear'                                                    # Clear terminal screen
alias cx='chmod +x'                                                  # Grant executable permission
alias chownme='sudo chown -R $USER:$USER'                            # Reclaim user ownership of path

alias rm='rm -i'                                                     # Interactive safe file removal
alias rmf='rm -rf'                                                   # Force recursive file/folder removal

alias lst4='tree -a -h -L 4'                                         # Tree view 4 levels deep
alias lst3='tree -a -h -L 3'                                         # Tree view 3 levels deep
alias lst2='tree -a -h -L 2'                                         # Tree view 2 levels deep
alias lst1='tree -a -h -L 1'                                         # Tree view 1 level deep

alias dfh='df -h'                                                    # Human-readable filesystem disk space
alias bigfiles='find . -type f -exec du -h {} + | sort -hr | head -20' # Top 20 largest files in tree

alias lg='lazygit'                                                   # Launch lazygit terminal UI

# WINDOWS POWER & SLEEP MANAGEMENT
if is_wsl || is_windows; then
  alias winsleep='zen sleep'                                         # Put Windows machine to sleep after countdown (default: 30m)
  alias sleepin='zen sleep'                                          # Put Windows machine to sleep after countdown (default: 30m)
fi

