#!/usr/bin/env bash
# ==============================================================================
# core/45-doctor-lib.sh - Zen Ecosystem Health & Diagnostic Engine
# ==============================================================================
# Inspects system environment, shell hooks, managed symlinks, Git invariants,
# and developer toolchain status recorded in .installed.json.
# ==============================================================================

_zen_doctor() {
  local pass_count=0
  local warn_count=0
  local fail_count=0

  local c_reset="\033[0m"
  local c_green="\033[1;32m"
  local c_yellow="\033[1;33m"
  local c_red="\033[1;31m"
  local c_cyan="\033[1;36m"
  local c_bold="\033[1m"
  local c_gray="\033[90m"

  local dotfiles_root
  if declare -F _get_dotfiles_root >/dev/null 2>&1; then
    dotfiles_root="$(_get_dotfiles_root)"
  else
    dotfiles_root="${DOTFILES:-${DOTFILES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles}}"
  fi
  local manifest_file="${XDG_CONFIG_HOME:-$HOME/.config}/zen/.installed.json"
  [[ -f "$manifest_file" ]] || manifest_file="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.installed.json"
  [[ -f "$manifest_file" ]] || manifest_file="$dotfiles_root/.installed.json"

  printf "\n${c_bold}${c_cyan}=== ZENCLI ECOSYSTEM HEALTH DOCTOR ===${c_reset}\n"
  printf "${c_gray}Authoritative Inspection & System Diagnostic Ledger${c_reset}\n\n"

  # ----------------------------------------------------------------------------
  # [1/5] Operating System & Environment
  # ----------------------------------------------------------------------------
  printf "${c_bold}[1/5] Operating System & Environment${c_reset}\n"
  local os_type="$(uname -s 2>/dev/null || echo "Unknown")"
  local kernel_ver="$(uname -r 2>/dev/null || echo "Unknown")"
  local arch="$(uname -m 2>/dev/null || echo "Unknown")"
  local distro="Linux"

  if [[ -f /etc/os-release ]]; then
    distro="$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"' || echo "Linux")"
  elif [[ "$os_type" == "Darwin" ]]; then
    distro="macOS $(sw_vers -productVersion 2>/dev/null || echo "")"
  fi

  printf "  ${c_green}✔${c_reset} OS: %s (%s, %s)\n" "$distro" "$kernel_ver" "$arch"
  ((pass_count++))

  if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    printf "  ${c_green}✔${c_reset} Platform: WSL (Windows Subsystem for Linux)\n"
    ((pass_count++))
  else
    printf "  ${c_green}✔${c_reset} Platform: Native POSIX (%s)\n" "$os_type"
    ((pass_count++))
  fi

  local tz_abbr="$(date +"%Z" 2>/dev/null || echo "UTC")"
  local tz_offset="$(date +"%:z" 2>/dev/null || echo "+00:00")"
  local tz_display="${TZ:-System ($tz_abbr)}"
  printf "  ${c_green}✔${c_reset} Timezone: %s (%s, UTC%s)\n" "$tz_display" "$tz_abbr" "$tz_offset"
  ((pass_count++))

  # ----------------------------------------------------------------------------
  # [2/5] Shell Profile Integration & Dotfiles Root
  # ----------------------------------------------------------------------------
  printf "\n${c_bold}[2/5] Shell Profile Integration${c_reset}\n"
  if [[ -d "$dotfiles_root" ]]; then
    printf "  ${c_green}✔${c_reset} Dotfiles Root: %s\n" "$dotfiles_root"
    ((pass_count++))
  else
    printf "  ${c_red}✖${c_reset} Dotfiles Root not found at %s\n" "$dotfiles_root"
    ((fail_count++))
  fi

  local shell_hook_found=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]] && grep -qE '# Load (dotfiles|zen|Zen)|(dotfiles|zen)/core' "$rc" 2>/dev/null; then
      printf "  ${c_green}✔${c_reset} Active profile hook verified in: %s\n" "$rc"
      shell_hook_found=1
      ((pass_count++))
    fi
  done

  if (( ! shell_hook_found )); then
    printf "  ${c_yellow}⚠${c_reset} No shell loader hook detected in ~/.bashrc or ~/.zshrc\n"
    ((warn_count++))
  fi

  # ----------------------------------------------------------------------------
  # [3/5] Managed Symlinks & Git Configuration
  # ----------------------------------------------------------------------------
  printf "\n${c_bold}[3/5] Managed Symlinks & Git Configuration${c_reset}\n"
  if [[ -f "$HOME/.gitconfig" ]] && grep -qE '(zen|dotfiles)/\.gitconfig' "$HOME/.gitconfig" 2>/dev/null; then
    printf "  ${c_green}✔${c_reset} Global Git config includes ZenCLI .gitconfig\n"
    ((pass_count++))
  else
    printf "  ${c_yellow}⚠${c_reset} ~/.gitconfig does not reference ZenCLI .gitconfig (Run 'zen setup git')\n"
    ((warn_count++))
  fi

  # Check symlinks recorded in manifest
  if [[ -f "$manifest_file" ]] && command -v python3 >/dev/null 2>&1; then
    local broken_links
    broken_links="$(python3 -c '
import json, os, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    symlinks = data.get("symlinks", [])
    broken = []
    for s in symlinks:
        link = s.get("link")
        target = s.get("target")
        if link and not os.path.exists(link):
            broken.append(f"{link} -> {target}")
    if broken:
        print("\n".join(broken))
except Exception:
    pass
' "$manifest_file" 2>/dev/null || true)"

    if [[ -n "$broken_links" ]]; then
      while IFS= read -r bline; do
        printf "  ${c_red}✖${c_reset} Broken symlink: %s\n" "$bline"
        ((fail_count++))
      done <<< "$broken_links"
    else
      printf "  ${c_green}✔${c_reset} Managed symlinks verified and healthy\n"
      ((pass_count++))
    fi
  fi

  # ----------------------------------------------------------------------------
  # [4/5] Managed Developer Toolchain Ledger (.installed.json)
  # ----------------------------------------------------------------------------
  printf "\n${c_bold}[4/5] Managed Developer Toolchain Ledger${c_reset}\n"
  local registered_tools=("git" "curl" "jq" "rg" "lazygit")
  for t in "${registered_tools[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
      local t_path
      t_path="$(command -v "$t")"
      local t_ver="installed"

      case "$t" in
        git)
          t_ver="$(git --version 2>/dev/null | awk '{print $3}')"
          ;;
        curl)
          t_ver="$(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
          ;;
        jq)
          t_ver="$(jq --version 2>/dev/null | sed -E 's/^jq-?//')"
          ;;
        rg)
          t_ver="$(rg --version 2>/dev/null | head -1 | awk '{print $2}')"
          ;;
        lazygit)
          local lz_raw lz_re
          lz_raw="$(lazygit --version 2>/dev/null || true)"
          lz_re="(, |^)version=[^0-9]*([0-9]+\.[0-9]+(\.[0-9]+)?)"
          if [[ "$lz_raw" =~ $lz_re ]]; then
            t_ver="${BASH_REMATCH[2]}"
          else
            t_ver="installed"
          fi
          ;;
      esac

      printf "  ${c_green}✔${c_reset} %-10s v%-12s (%s)\n" "$t" "$t_ver" "$t_path"
      ((pass_count++))
    else
      printf "  ${c_yellow}⚠${c_reset} %-10s %-13s (Run 'zen i %s' or 'zen i --all')\n" "$t" "NOT INSTALLED" "$t"
      ((warn_count++))
    fi
  done

  # ----------------------------------------------------------------------------
  # [5/5] Command Audit Log & State Ledger
  # ----------------------------------------------------------------------------
  printf "\n${c_bold}[5/5] Command Audit Log & State Directory${c_reset}\n"
  local log_file="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/commands.log"
  local log_dir="$(dirname "$log_file")"
  if [[ -w "$log_dir" || ( ! -d "$log_dir" && -w "$(dirname "$log_dir")" ) ]]; then
    local log_size="0 B"
    if [[ -f "$log_file" ]]; then
      log_size="$(du -h "$log_file" 2>/dev/null | awk '{print $1}')"
    fi
    printf "  ${c_green}✔${c_reset} Command log ready: %s (%s)\n" "$log_file" "$log_size"
    ((pass_count++))
  else
    printf "  ${c_yellow}⚠${c_reset} Command log directory not writable: %s\n" "$log_dir"
    ((warn_count++))
  fi

  # ----------------------------------------------------------------------------
  # Diagnostic Summary
  # ----------------------------------------------------------------------------
  printf "\n${c_bold}Diagnostic Summary:${c_reset} "
  if (( fail_count == 0 && warn_count == 0 )); then
    printf "${c_green}ALL SYSTEMS OPERATIONAL${c_reset} (%d checks passed)\n\n" "$pass_count"
    return 0
  elif (( fail_count == 0 )); then
    printf "${c_yellow}HEALTHY WITH NOTICES${c_reset} (%d passed, %d notices)\n\n" "$pass_count" "$warn_count"
    return 0
  else
    printf "${c_red}ACTION REQUIRED${c_reset} (%d failed, %d notices, %d passed)\n\n" "$fail_count" "$warn_count" "$pass_count"
    return 1
  fi
}
