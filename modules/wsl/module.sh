# WINDOWS & WSL HELPERS

_default_win_dir="${_WIN_DIR:-/mnt/c/Windows}"
[[ -d "/c/Windows" && -z "${_WIN_DIR:-}" ]] && _default_win_dir="/c/Windows"
_WIN="${DOTFILES_WIN_PATH:-$_default_win_dir}"
_CLIP="$_WIN/System32/clip.exe"
_EXPLORER="$_WIN/explorer.exe"
_POWERSHELL="$_WIN/System32/WindowsPowerShell/v1.0/powershell.exe"

clip() {
  if [[ -x "$_CLIP" ]]; then
    "$_CLIP" "$@"
  elif command -v clip.exe &>/dev/null; then
    clip.exe "$@"
  else
    echo "❌ clip.exe not found at $_CLIP" >&2
    return 1
  fi
}

explorer() {
  if [[ -x "$_EXPLORER" ]]; then
    "$_EXPLORER" "$@"
  elif command -v explorer.exe &>/dev/null; then
    explorer.exe "$@"
  else
    echo "❌ explorer.exe not found at $_EXPLORER" >&2
    return 1
  fi
}

powershell() {
  if [[ -x "$_POWERSHELL" ]]; then
    "$_POWERSHELL" "$@"
  elif command -v powershell.exe &>/dev/null; then
    powershell.exe "$@"
  else
    echo "❌ powershell.exe not found at $_POWERSHELL" >&2
    return 1
  fi
}

winpath() {
  wslpath -w "${1:-$PWD}"
}

opene() {
  explorer "$(winpath "${1:-$PWD}")"
}

cpath() {
  local p
  p=$(winpath "${1:-$PWD}")
  echo "Copied: $p"
  printf '%s' "$p" | clip
}

wcp() {
  (($# == 2)) || {
    echo "Usage: wcp <src> <dst>"
    return 1
  }

  local src="$1" dst="$2"

  [[ $src =~ ^[A-Za-z]:[\\/].* ]] && src=$(wslpath -u "$src")
  [[ $dst =~ ^[A-Za-z]:[\\/].* ]] && dst=$(wslpath -u "$dst")

  echo "$src → $dst"
  _run_confirm cp "$src" "$dst"
}

# Sleep Windows host after X minutes from WSL
unalias sleepin 2>/dev/null || true
unalias winsleep 2>/dev/null || true
sleepin() {
  local minutes="${1:-30}"
  if ! [[ "$minutes" =~ ^[0-9]+$ ]] || (( minutes < 0 )); then
    echo "Usage: sleepin [minutes] (default: 30)" >&2
    return 1
  fi

  local dotfiles_root
  if declare -F _get_dotfiles_root >/dev/null 2>&1; then
    dotfiles_root="$(_get_dotfiles_root)"
  else
    dotfiles_root="${ZENCLI:-${ZEN:-${XDG_CONFIG_HOME:-$HOME/.config}/zencli}}"
    [[ -d "$dotfiles_root" ]] || dotfiles_root="$HOME/.config/zencli"
  fi

  local ps_script="$dotfiles_root/scripts/sleep.ps1"
  if [[ -f "$ps_script" ]] && command -v wslpath >/dev/null 2>&1; then
    local win_path
    win_path="$(wslpath -w "$ps_script")"
    powershell -NoProfile -ExecutionPolicy Bypass -File "$win_path" -Minutes "$minutes"
  else
    echo "Computer will sleep in $minutes minute(s). Press Ctrl+C to cancel."
    powershell -NoProfile -Command "Start-Sleep -Seconds ($minutes * 60); Add-Type -Namespace Win32 -Name Power -MemberDefinition '[DllImport(\"PowrProf.dll\", SetLastError = true)] public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);'; [Win32.Power]::SetSuspendState(\$false, \$false, \$false) | Out-Null"
  fi
}
alias winsleep='sleepin' # Put Windows computer to sleep after X minutes
