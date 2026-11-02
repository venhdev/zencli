#!/usr/bin/env bash
# ==============================================================================
# scripts/install-tools.sh - Zen Developer Tools Notebook Manager
# ==============================================================================
# Interactive TUI notebook to inventory, install, update, remove, and audit
# developer CLI tools across APT and upstream GitHub releases.
# ==============================================================================
set -e

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DOTFILES_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

# Source SSOT libraries
if [[ -f "$_DOTFILES_ROOT/core/00-platform-lib.sh" ]]; then
  # shellcheck source=../core/00-platform-lib.sh
  . "$_DOTFILES_ROOT/core/00-platform-lib.sh"
else
  is_msys() { [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "cygwin"* || "$(uname -s 2>/dev/null)" == MSYS* ]]; }
  is_darwin() { [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; }
  has_apt() { command -v apt-get >/dev/null 2>&1; }
fi

if [[ -f "$_DOTFILES_ROOT/core/05-tui-lib.sh" ]]; then
  # shellcheck source=../core/05-tui-lib.sh
  . "$_DOTFILES_ROOT/core/05-tui-lib.sh"
fi

# Pre-flight OS check
if is_msys; then
  echo "Notice: Common CLI tools installer is not applicable on Windows (Git Bash)."
  echo "Git and curl are bundled with Git Bash. Use winget, choco, or scoop to manage Windows packages."
  exit 0
fi

if is_darwin; then
  echo "Notice: Common CLI tools installer currently targets Debian/Ubuntu (apt/binary)."
  echo "On macOS, please use Homebrew: brew install git curl jq ripgrep lazygit"
  exit 0
fi

# ==============================================================================
# DECLARATIVE TOOL NOTEBOOK REGISTRY
# format: cmd|apt_pkg|gh_repo|asset_template|bin_in_archive|desc|homepage
# ==============================================================================
TOOL_NOTEBOOK=(
  "git|git||||Fast, distributed version control system|https://git-scm.com"
  "curl|curl||||CLI tool for transferring data with URLs|https://curl.se"
  "jq|jq||||Command-line JSON processor|https://jqlang.github.io/jq/"
  "rg|ripgrep|BurntSushi/ripgrep|ripgrep_{ver}_{arch}-unknown-linux-musl.tar.gz|rg|ripgrep line-oriented search tool|https://github.com/BurntSushi/ripgrep"
  "lazygit|lazygit|jesseduffield/lazygit|lazygit_{ver}_Linux_{arch}.tar.gz|lazygit|Simple terminal UI for git commands|https://github.com/jesseduffield/lazygit"
)

# CLI Options
OPT_ALL=0
for arg in "$@"; do
  case "$arg" in
    -a|--all|-y|--yes)
      OPT_ALL=1
      ;;
    -h|--help)
      echo "Usage: ./install-tools.sh [OPTIONS]"
      echo
      echo "Options:"
      echo "  -a, --all, -y, --yes  Install missing APT packages non-interactively"
      echo "  -h, --help            Show this help message"
      echo
      echo "Interactive mode:"
      echo "  Run without arguments to launch the Zen Tools Notebook TUI."
      exit 0
      ;;
  esac
done

# Safe Single-Token Installed Version Extractor
_get_tool_version() {
  local cmd="$1"
  case "$cmd" in
    git)
      git --version 2>/dev/null | awk '{print $3}'
      ;;
    curl)
      curl --version 2>/dev/null | awk 'NR==1{print $2}'
      ;;
    jq)
      jq --version 2>/dev/null | sed 's/^jq-//'
      ;;
    rg)
      rg --version 2>/dev/null | awk 'NR==1{print $2}'
      ;;
    lazygit)
      local raw lz_re
      raw="$(lazygit --version 2>/dev/null || true)"
      lz_re="(, |^)version=[^0-9]*([0-9]+\.[0-9]+(\.[0-9]+)?)"
      if [[ "$raw" =~ $lz_re ]]; then
        echo "${BASH_REMATCH[2]}"
      else
        echo "installed"
      fi
      ;;
    delta)
      delta --version 2>/dev/null | awk '{print $2}'
      ;;
    starship)
      starship --version 2>/dev/null | awk 'NR==1{print $2}'
      ;;
    zoxide)
      zoxide --version 2>/dev/null | awk '{print $2}'
      ;;
    *)
      local raw
      raw="$("$cmd" --version 2>/dev/null | head -n 1 || true)"
      if [[ "$raw" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
      else
        echo "ok"
      fi
      ;;
  esac
}

# Fast Candidate Version from Local APT Cache (without network calls)
_get_apt_candidate() {
  local pkg="$1"
  [[ -n "$pkg" ]] || return 1
  has_apt || return 1
  local cand
  cand="$(apt-cache policy "$pkg" 2>/dev/null | grep -i "Candidate:" | awk '{print $2}' || true)"
  if [[ -n "$cand" && "$cand" != "(none)" ]]; then
    # Strip Debian epoch prefix and build suffixes (e.g., 1:2.47.3-0+deb13u1 -> 2.47.3)
    cand="${cand#*:}"
    cand="${cand%%-*}"
    cand="${cand%%\+*}"
    echo "$cand"
    return 0
  fi
  return 1
}

# Hardware Architecture Normalization
_get_arch() {
  local m
  m="$(uname -m 2>/dev/null || echo "x86_64")"
  case "$m" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf) echo "armv7" ;;
    i386|i686) echo "32-bit" ;;
    *) echo "$m" ;;
  esac
}

# Check if a package is available in APT repositories
_is_in_apt() {
  local pkg="$1"
  [[ -n "$pkg" ]] || return 1
  has_apt || return 1
  apt-cache show "$pkg" >/dev/null 2>&1
}

# Resolve Latest Release Tag from GitHub (with redirect fallback for API rate limit)
_get_github_latest_ver() {
  local repo="$1"
  local ver=""

  # Try API first
  ver="$(curl -s --connect-timeout 4 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | grep -Po '"tag_name":\s*"\K[^"]*' || true)"
  if [[ -n "$ver" ]]; then
    echo "${ver#v}"
    return 0
  fi

  # Fallback to HTTP redirect header (zero API rate limit consumption)
  local redirect_url
  redirect_url="$(curl -sI --connect-timeout 4 "https://github.com/${repo}/releases/latest" 2>/dev/null | grep -i '^location:' | awk '{print $2}' | tr -d '\r\n' || true)"
  if [[ "$redirect_url" =~ /tag/(v?)([^/]+)$ ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi

  echo "unknown"
  return 1
}

# Detect Installation Source & Path of a Command
_detect_origin() {
  local cmd="$1"
  local bin_path
  bin_path="$(command -v "$cmd" 2>/dev/null || true)"

  if [[ -z "$bin_path" ]]; then
    echo "NONE|-|-"
    return 0
  fi

  # Local user binary directory
  if [[ "$bin_path" == "$HOME/.local/bin/"* ]]; then
    echo "github (local)|$bin_path|local"
    return 0
  fi

  # System package manager check
  if command -v dpkg >/dev/null 2>&1; then
    if dpkg -S "$bin_path" >/dev/null 2>&1; then
      echo "apt (system)|$bin_path|apt"
      return 0
    fi
  fi

  echo "system|$bin_path|system"
}

# ==============================================================================
# MANIFEST LEDGER SYNC HELPERS (.installed.json)
# ==============================================================================
_get_manifest_path() {
  local candidates=(
    "${DOTFILES_DIR:-}/.installed.json"
    "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.installed.json"
    "$_DOTFILES_ROOT/.installed.json"
  )
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/.installed.json"
}

_manifest_get_tool_info() {
  local cmd="$1"
  local manifest_file
  manifest_file="$(_get_manifest_path)"
  [[ -f "$manifest_file" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1

  python3 -c '
import json, sys
manifest_path, cmd = sys.argv[1:3]
try:
    with open(manifest_path, "r") as f:
        data = json.load(f)
    t = data.get("tools", {}).get(cmd, {})
    if t:
        print(f"{t.get(\"installed_at\", \"-\")}|{t.get(\"updated_at\", \"-\")}")
except Exception:
    pass
' "$manifest_file" "$cmd" 2>/dev/null || true
}

_manifest_sync_tool() {
  local cmd="$1"
  local origin="$2"
  local pkg="$3"
  local ver="$4"
  local bin_path="$5"
  local repo="$6"
  local manifest_file
  manifest_file="$(_get_manifest_path)"

  command -v python3 >/dev/null 2>&1 || return 0

  python3 -c '
import json, os, sys, datetime

manifest_path, cmd, origin, pkg, ver, bin_path, repo = sys.argv[1:8]
data = {"version": "1.1.0", "tools": {}}
if os.path.exists(manifest_path):
    try:
        with open(manifest_path, "r") as f:
            data = json.load(f)
    except Exception:
        pass

tools = data.setdefault("tools", {})
existing = tools.get(cmd, {})
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

tools[cmd] = {
    "origin": origin,
    "package": pkg or cmd,
    "installed_version": ver,
    "binary_path": bin_path,
    "upstream_repo": repo or existing.get("upstream_repo", ""),
    "installed_at": existing.get("installed_at", now),
    "updated_at": now,
    "last_checked_at": now
}
data["version"] = "1.1.0"

manifest_dir = os.path.dirname(manifest_path)
if manifest_dir and not os.path.exists(manifest_dir):
    os.makedirs(manifest_dir, exist_ok=True)

tmp_path = manifest_path + ".tmp"
with open(tmp_path, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp_path, manifest_path)
' "$manifest_file" "$cmd" "$origin" "$pkg" "$ver" "$bin_path" "$repo" 2>/dev/null || true
}

_manifest_remove_tool() {
  local cmd="$1"
  local manifest_file
  manifest_file="$(_get_manifest_path)"

  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$manifest_file" ]] || return 0

  python3 -c '
import json, os, sys

manifest_path, cmd = sys.argv[1:3]
if not os.path.exists(manifest_path):
    sys.exit(0)

try:
    with open(manifest_path, "r") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

tools = data.get("tools", {})
if cmd in tools:
    del tools[cmd]
    tmp_path = manifest_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp_path, manifest_path)
' "$manifest_file" "$cmd" 2>/dev/null || true
}

# Dynamic Ledger In-memory State
item_count=${#TOOL_NOTEBOOK[@]}
cmds=()
apt_pkgs=()
gh_repos=()
asset_fmts=()
bin_names=()
descs=()
homepages=()

statuses=()
versions=()
origins=()
paths=()
selected=()

_refresh_inventory() {
  cmds=()
  apt_pkgs=()
  gh_repos=()
  asset_fmts=()
  bin_names=()
  descs=()
  homepages=()

  statuses=()
  versions=()
  origins=()
  paths=()
  apt_candidates=()
  apt_infos=()
  manifest_dates=()

  local i def cmd apt_pkg gh_repo asset_fmt bin_name desc homepage
  local origin_info origin_label path_val origin_type ver_str cand_str

  for ((i=0; i<item_count; i++)); do
    def="${TOOL_NOTEBOOK[i]}"
    IFS='|' read -r cmd apt_pkg gh_repo asset_fmt bin_name desc homepage <<< "$def"
    cmds+=("$cmd")
    apt_pkgs+=("$apt_pkg")
    gh_repos+=("$gh_repo")
    asset_fmts+=("$asset_fmt")
    bin_names+=("${bin_name:-$cmd}")
    descs+=("$desc")
    homepages+=("$homepage")

    origin_info="$(_detect_origin "$cmd")"
    IFS='|' read -r origin_label path_val origin_type <<< "$origin_info"
    origins+=("$origin_label")
    paths+=("$path_val")

    # Pre-cache candidate version and APT info once
    cand_str="$(_get_apt_candidate "$apt_pkg" || true)"
    apt_candidates+=("$cand_str")

    local apt_info="Not in current APT repositories"
    if [[ -n "$cand_str" ]]; then
      apt_info="Available in APT ($apt_pkg v$cand_str)"
    elif _is_in_apt "$apt_pkg"; then
      apt_info="Available in APT ($apt_pkg)"
    fi
    apt_infos+=("$apt_info")

    if [[ "$origin_label" == "NONE" ]]; then
      statuses+=(0) # Not installed
      if [[ -n "$cand_str" ]]; then
        versions+=("($cand_str)")
      else
        versions+=("-")
      fi
      manifest_dates+=("-")
    else
      statuses+=(1) # Installed
      ver_str="$(_get_tool_version "$cmd")"
      versions+=("${ver_str:--}")

      # Pre-cache manifest installed date once during inventory refresh
      local inst_date="-"
      local minfo
      minfo="$(_manifest_get_tool_info "$cmd" || true)"
      if [[ -n "$minfo" ]]; then
        inst_date="${minfo%%|*}"
      fi
      manifest_dates+=("$inst_date")

      # Auto-sync active installed tool into manifest if manifest exists
      local clean_origin="apt"
      [[ "$origin_label" == *"github"* ]] && clean_origin="github"
      _manifest_sync_tool "$cmd" "$clean_origin" "$apt_pkg" "${ver_str:--}" "$path_val" "$gh_repo"
    fi

    # Maintain existing selection or default to unselected
    if [[ -z "${selected[i]:-}" ]]; then
      selected+=(0)
    fi
  done
}

# Initial inventory load & manifest sync
_refresh_inventory

# Non-interactive CLI Mode Handler
if (( OPT_ALL )); then
  missing_apt=()
  missing_gh=()

  for ((i=0; i<item_count; i++)); do
    if (( statuses[i] == 0 )); then
      if _is_in_apt "${apt_pkgs[i]}"; then
        missing_apt+=("${apt_pkgs[i]}")
      elif [[ -n "${gh_repos[i]}" ]]; then
        missing_gh+=("${cmds[i]}")
      fi
    fi
  done

  if (( ${#missing_apt[@]} == 0 && ${#missing_gh[@]} == 0 )); then
    echo "✔ All registered tools are already installed."
    exit 0
  fi

  if (( ${#missing_apt[@]} > 0 )); then
    echo "==> Updating package index (sudo apt update)..."
    sudo apt update
    echo "==> Installing missing packages via APT: ${missing_apt[*]}..."
    sudo apt install -y "${missing_apt[@]}"
  fi

  if (( ${#missing_gh[@]} > 0 )); then
    echo
    echo "Notice: The following tools are not available in current APT repositories: ${missing_gh[*]}"
    echo "To install upstream binaries into ~/.local/bin safely with explicit review, launch the notebook:"
    echo "  zen (or ./scripts/install-tools.sh)"
  fi

  echo
  printf "\033[1;32m✔ Non-interactive package processing completed.\033[0m\n"
  exit 0
fi

# Check interactive TTY capabilities
if ! _tui_is_interactive; then
  echo "Non-interactive environment detected. Use -a or -y to install via apt."
  exit 0
fi

# ==============================================================================
# ACTION HANDLERS (Install, Update, Delete)
# ==============================================================================

# Download and Install GitHub Pre-built Binary
_install_from_github() {
  local cmd="$1"
  local repo="$2"
  local asset_pattern="$3"
  local bin_name="$4"
  local desc="$5"

  local arch
  arch="$(_get_arch)"

  printf "\n${_TUI_CYAN}==> Querying latest release from GitHub (${repo})...${_TUI_RESET}\n" >/dev/tty
  local ver
  ver="$(_get_github_latest_ver "$repo")"

  if [[ "$ver" == "unknown" || -z "$ver" ]]; then
    printf "${_TUI_RED}Error: Unable to connect to GitHub Releases to determine version for %s.${_TUI_RESET}\n" "$cmd" >/dev/tty
    return 1
  fi

  # Render asset filename from pattern
  local asset_file="$asset_pattern"
  asset_file="${asset_file//\{ver\}/$ver}"
  asset_file="${asset_file//\{arch\}/$arch}"
  asset_file="${asset_file//\{os\}/Linux}"

  local download_url="https://github.com/${repo}/releases/download/v${ver}/${asset_file}"
  local target_dir="$HOME/.local/bin"

  # Display Transparency Card
  printf "\n${_TUI_GRAY}────────────────────────────────────────────────────────────────────────${_TUI_RESET}\n" >/dev/tty
  printf "${_TUI_CYAN}${_TUI_BOLD} [OFFICIAL PRE-BUILT BINARY INSTALLATION]${_TUI_RESET}\n" >/dev/tty
  printf " • Tool         : %s (%s)\n" "$cmd" "$desc" >/dev/tty
  printf " • Repository   : https://github.com/%s\n" "$repo" >/dev/tty
  printf " • Release Page : https://github.com/%s/releases\n" "$repo" >/dev/tty
  printf " • Version      : v%s (Architecture: %s)\n" "$ver" "$arch" >/dev/tty
  printf " • Asset File   : %s\n" "$asset_file" >/dev/tty
  printf " • Exact URL    : %s\n" "$download_url" >/dev/tty
  printf " • Target Path  : %s/%s ${_TUI_GREEN}(User-space, no sudo required)${_TUI_RESET}\n" "$target_dir" "$cmd" >/dev/tty
  printf "${_TUI_GRAY}────────────────────────────────────────────────────────────────────────${_TUI_RESET}\n" >/dev/tty

  if ! _tui_confirm_prompt "Do you want to download and install this binary from the official release above?" "N"; then
    printf "${_TUI_YELLOW}[-] Skipped binary installation for %s.${_TUI_RESET}\n" "$cmd" >/dev/tty
    printf "    Manual installation instructions: https://github.com/%s#installation\n" "$repo" >/dev/tty
    return 0
  fi

  mkdir -p "$target_dir"
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  printf "==> Downloading %s...\n" "$download_url" >/dev/tty
  if ! curl -sL --fail "$download_url" -o "$tmp_dir/$asset_file"; then
    local alt_url="https://github.com/${repo}/releases/download/${ver}/${asset_file}"
    if ! curl -sL --fail "$alt_url" -o "$tmp_dir/$asset_file"; then
      printf "${_TUI_RED}Error: Download failed from both candidate URLs:${_TUI_RESET}\n 1. %s\n 2. %s\n" "$download_url" "$alt_url" >/dev/tty
      rm -rf "$tmp_dir"
      return 1
    fi
  fi

  printf "==> Extracting and installing to %s/%s...\n" "$target_dir" "$cmd" >/dev/tty
  if [[ "$asset_file" == *.tar.gz || "$asset_file" == *.tgz ]]; then
    tar -xzf "$tmp_dir/$asset_file" -C "$tmp_dir"
  elif [[ "$asset_file" == *.zip ]]; then
    unzip -q "$tmp_dir/$asset_file" -d "$tmp_dir"
  fi

  # Find binary location inside extracted tree
  local extracted_bin=""
  if [[ -f "$tmp_dir/$bin_name" ]]; then
    extracted_bin="$tmp_dir/$bin_name"
  else
    extracted_bin="$(find "$tmp_dir" -type f -name "$bin_name" | head -n 1)"
  fi

  if [[ -z "$extracted_bin" || ! -f "$extracted_bin" ]]; then
    printf "${_TUI_RED}Error: Executable '%s' not found inside extracted archive.${_TUI_RESET}\n" "$bin_name" >/dev/tty
    rm -rf "$tmp_dir"
    return 1
  fi

  install -m 755 "$extracted_bin" "$target_dir/$cmd"
  rm -rf "$tmp_dir"

  # Sync into state manifest ledger
  _manifest_sync_tool "$cmd" "github" "$cmd" "$ver" "$target_dir/$cmd" "$repo"

  printf "${_TUI_GREEN}${_TUI_BOLD}✔ Successfully installed %s v%s to %s/%s${_TUI_RESET}\n" "$cmd" "$ver" "$target_dir" "$cmd" >/dev/tty
}

_action_install() {
  local target_indices=()
  for ((i=0; i<item_count; i++)); do
    (( selected[i] )) && target_indices+=("$i")
  done

  if (( ${#target_indices[@]} == 0 )); then
    target_indices+=("$cursor")
  fi

  local apt_queue=()
  local gh_queue=()

  for idx in "${target_indices[@]}"; do
    local c="${cmds[idx]}"
    local pkg="${apt_pkgs[idx]}"
    local repo="${gh_repos[idx]}"

    if _is_in_apt "$pkg"; then
      apt_queue+=("$pkg")
    elif [[ -n "$repo" ]]; then
      gh_queue+=("$idx")
    else
      printf "${_TUI_RED}Package '%s' is not in APT and has no GitHub release source.${_TUI_RESET}\n" "$c" >/dev/tty
    fi
  done

  _tui_exit

  # 1. Standard APT flow (prompts sudo password naturally)
  if (( ${#apt_queue[@]} > 0 )); then
    printf "\n${_TUI_CYAN}${_TUI_BOLD}=== SYSTEM APT INSTALLATION ===${_TUI_RESET}\n"
    printf "Packages to install via APT: ${_TUI_GREEN}%s${_TUI_RESET}\n\n" "${apt_queue[*]}"
    if _tui_confirm_prompt "Proceed with 'sudo apt update && sudo apt install'?" "Y"; then
      sudo apt update && sudo apt install -y "${apt_queue[@]}"
      for idx in "${target_indices[@]}"; do
        local c="${cmds[idx]}"
        local pkg="${apt_pkgs[idx]}"
        if _is_in_apt "$pkg" && command -v "$c" >/dev/null 2>&1; then
          _manifest_sync_tool "$c" "apt" "$pkg" "$(_get_tool_version "$c")" "$(command -v "$c")" "${gh_repos[idx]}"
        fi
      done
    fi
  fi

  # 2. Explicit Opt-in GitHub Binary Flow
  if (( ${#gh_queue[@]} > 0 )); then
    for g_idx in "${gh_queue[@]}"; do
      _install_from_github "${cmds[g_idx]}" "${gh_repos[g_idx]}" "${asset_fmts[g_idx]}" "${bin_names[g_idx]}" "${descs[g_idx]}"
    done
  fi

  printf "\n${_TUI_GRAY}Press Enter to return to ZenCLI Notebook...${_TUI_RESET}"
  read -r _ </dev/tty || true
  _tui_enter
}

_action_update() {
  local target_indices=()
  for ((i=0; i<item_count; i++)); do
    (( selected[i] )) && target_indices+=("$i")
  done

  if (( ${#target_indices[@]} == 0 )); then
    target_indices+=("$cursor")
  fi

  _tui_exit
  local apt_updates=()

  for idx in "${target_indices[@]}"; do
    if (( statuses[idx] == 0 )); then
      printf "${_TUI_YELLOW}Skipping '%s' (not currently installed).${_TUI_RESET}\n" "${cmds[idx]}"
      continue
    fi

    local orig="${origins[idx]}"
    if [[ "$orig" == *"apt"* ]]; then
      apt_updates+=("${apt_pkgs[idx]}")
    elif [[ "$orig" == *"github"* && -n "${gh_repos[idx]}" ]]; then
      _install_from_github "${cmds[idx]}" "${gh_repos[idx]}" "${asset_fmts[idx]}" "${bin_names[idx]}" "${descs[idx]}"
    else
      printf "Tool '%s' origin '%s' does not support automated updates.\n" "${cmds[idx]}" "$orig"
    fi
  done

  if (( ${#apt_updates[@]} > 0 )); then
    printf "\n==> Updating APT packages: %s...\n" "${apt_updates[*]}"
    sudo apt update && sudo apt --only-upgrade install -y "${apt_updates[@]}"
    for idx in "${target_indices[@]}"; do
      local c="${cmds[idx]}"
      local pkg="${apt_pkgs[idx]}"
      if command -v "$c" >/dev/null 2>&1; then
        _manifest_sync_tool "$c" "apt" "$pkg" "$(_get_tool_version "$c")" "$(command -v "$c")" "${gh_repos[idx]}"
      fi
    done
  fi

  printf "\n${_TUI_GRAY}Press Enter to return to ZenCLI Notebook...${_TUI_RESET}"
  read -r _ </dev/tty || true
  _tui_enter
}

_action_delete() {
  local target_indices=()
  for ((i=0; i<item_count; i++)); do
    (( selected[i] )) && target_indices+=("$i")
  done

  if (( ${#target_indices[@]} == 0 )); then
    target_indices+=("$cursor")
  fi

  local to_delete=()
  for idx in "${target_indices[@]}"; do
    (( statuses[idx] == 1 )) && to_delete+=("$idx")
  done

  if (( ${#to_delete[@]} == 0 )); then
    _tui_exit
    printf "\n${_TUI_YELLOW}No installed tools selected for removal.${_TUI_RESET}\n"
    sleep 1.2
    _tui_enter
    return 0
  fi

  _tui_exit
  local delete_names=()
  for idx in "${to_delete[@]}"; do delete_names+=("${cmds[idx]}"); done

  printf "\n${_TUI_RED}${_TUI_BOLD}=== CONFIRM REMOVAL ===${_TUI_RESET}\n"
  printf "The following tools will be uninstalled: ${_TUI_YELLOW}%s${_TUI_RESET}\n" "${delete_names[*]}"

  if ! _tui_confirm_prompt "Are you sure you want to proceed?" "N"; then
    printf "Removal cancelled.\n"
    sleep 1
    _tui_enter
    return 0
  fi

  for idx in "${to_delete[@]}"; do
    local c="${cmds[idx]}"
    local orig="${origins[idx]}"
    local p="${paths[idx]}"
    local pkg="${apt_pkgs[idx]}"

    if [[ "$orig" == *"github"* || "$p" == "$HOME/.local/bin/"* ]]; then
      rm -f "$p"
      printf "${_TUI_GREEN}✔ Removed user binary: %s${_TUI_RESET}\n" "$p"
      _manifest_remove_tool "$c"
    elif [[ "$orig" == *"apt"* ]]; then
      sudo apt remove -y "$pkg"
      _manifest_remove_tool "$c"
    else
      printf "${_TUI_YELLOW}Skipping '%s': unable to auto-remove origin '%s'.${_TUI_RESET}\n" "$c" "$orig"
    fi
  done

  printf "\n${_TUI_GRAY}Press Enter to return to ZenCLI Notebook...${_TUI_RESET}"
  read -r _ </dev/tty || true
  _tui_enter
}

# ==============================================================================
# LIVE DETAIL PREVIEW PANE (Updates dynamically as cursor scrolls)
# ==============================================================================
# MASTER-DETAIL LIVE PREVIEW PANE (Responsive & Zero-Fork)
# ==============================================================================
_render_live_detail() {
  local idx="$1"
  _tui_update_dimensions
  local cols="${_TUI_COLS:-80}"
  local lines="${_TUI_LINES:-24}"

  # Omit detail box if vertical space is constrained
  if (( lines < 16 )); then
    return 0
  fi

  local c="${cmds[idx]}"
  local d="${descs[idx]}"
  local h="${homepages[idx]}"
  local s="NOT INSTALLED"
  (( statuses[idx] == 1 )) && s="INSTALLED"
  local v="${versions[idx]}"
  local o="${origins[idx]}"
  [[ "$o" == "NONE" ]] && o="-"
  local p="${paths[idx]}"
  [[ "$p" == "-" ]] && p="None"

  # Read pre-cached values without any subshell fork
  local apt_cand="${apt_candidates[idx]:-None}"
  local apt_info="${apt_infos[idx]:-Not in current APT repositories}"
  local inst_date="${manifest_dates[idx]:--}"

  local gh_info="None (Native APT)"
  [[ -n "${gh_repos[idx]}" ]] && gh_info="https://github.com/${gh_repos[idx]}"

  local width=$(( cols - 4 ))
  (( width > 80 )) && width=80
  (( width < 36 )) && return 0
  local inner_width=$(( width - 4 ))

  printf "\n" >/dev/tty
  local title_part="┌─[ DETAIL: $c ]"
  local pad_len=$(( width - ${#title_part} - 1 ))
  (( pad_len < 0 )) && pad_len=0
  local top_dashes
  top_dashes="$(_tui_repeat_char "─" "$pad_len")"
  printf "${_TUI_CYAN}${_TUI_BOLD}%s%s┐${_TUI_RESET}\n" "$title_part" "$top_dashes" >/dev/tty

  local detail_lines=(
    "Description       : $d"
    "Status            : $s"
    "Installed Version : $v"
    "Available Version : ${apt_cand:-None}"
    "Managed Origin    : $o"
  )

  # Adapt vertical detail density based on available terminal lines
  if (( lines >= 26 )); then
    detail_lines+=(
      "Binary Location   : $p"
      "Installed Date    : $inst_date"
      "APT Repository    : $apt_info"
      "GitHub Upstream   : $gh_info"
      "Official Homepage : $h"
    )
  elif (( lines >= 20 )); then
    detail_lines+=(
      "Binary Location   : $p"
      "Installed Date    : $inst_date"
    )
  fi

  for line in "${detail_lines[@]}"; do
    local trunc_line
    trunc_line="$(_tui_truncate "$line" "$inner_width")"
    printf "${_TUI_CYAN}│${_TUI_RESET} %-*s ${_TUI_CYAN}│${_TUI_RESET}\n" "$inner_width" "$trunc_line" >/dev/tty
  done

  local bot_dashes
  bot_dashes="$(_tui_repeat_char "─" "$(( width - 2 ))")"
  printf "${_TUI_CYAN}└%s┘${_TUI_RESET}\n" "$bot_dashes" >/dev/tty
}

# ==============================================================================
# MAIN TUI INTERACTIVE LOOP
# ==============================================================================
cursor=0
_tui_enter

while true; do
  _tui_clear
  _tui_update_dimensions
  cols="${_TUI_COLS:-80}"

  _tui_draw_header "ZENCLI: DEVELOPER TOOLS NOTEBOOK" "Developer Tool Ledger & Provisioning Manager"

  # Responsive Table Columns based on available width
  if (( cols >= 85 )); then
    printf "      %-10s %-13s %-10s %-15s %s\n" "COMMAND" "STATUS" "VERSION" "ORIGIN" "DESCRIPTION" >/dev/tty
    printf "      %-10s %-13s %-10s %-15s %s\n" "───────" "──────" "───────" "──────" "───────────" >/dev/tty
  elif (( cols >= 62 )); then
    printf "      %-10s %-13s %-10s %-15s\n" "COMMAND" "STATUS" "VERSION" "ORIGIN" >/dev/tty
    printf "      %-10s %-13s %-10s %-15s\n" "───────" "──────" "───────" "──────" >/dev/tty
  else
    printf "      %-8s %-11s %-8s\n" "COMMAND" "STATUS" "VER" >/dev/tty
    printf "      %-8s %-11s %-8s\n" "───────" "──────" "───" >/dev/tty
  fi

  # Render Rows
  for ((i=0; i<item_count; i++)); do
    mark=" "
    (( selected[i] )) && mark="x"

    if (( statuses[i] )); then
      status_disp="${_TUI_GREEN}Installed    ${_TUI_RESET}"
      status_short="${_TUI_GREEN}Inst ${_TUI_RESET}"
    else
      status_disp="${_TUI_GRAY}Not Installed${_TUI_RESET}"
      status_short="${_TUI_GRAY}None ${_TUI_RESET}"
    fi

    ver_disp="${versions[i]}"
    orig_disp="${origins[i]}"
    [[ "$orig_disp" == "NONE" ]] && orig_disp="-"

    prefix="  "
    if (( i == cursor )); then
      prefix="${_TUI_GREEN}${_TUI_BOLD}> ${_TUI_RESET}"
    fi

    if (( cols >= 85 )); then
      desc_avail=$(( cols - 58 ))
      desc_trunc="$(_tui_truncate "${descs[i]}" "$desc_avail")"
      printf "%b[%s] %-10s %b %-10s %-15s %s\n" \
        "$prefix" "$mark" "${cmds[i]}" "$status_disp" "$ver_disp" "$orig_disp" "$desc_trunc" >/dev/tty
    elif (( cols >= 62 )); then
      printf "%b[%s] %-10s %b %-10s %-15s\n" \
        "$prefix" "$mark" "${cmds[i]}" "$status_disp" "$ver_disp" "$orig_disp" >/dev/tty
    else
      printf "%b[%s] %-8s %b %-8s\n" \
        "$prefix" "$mark" "${cmds[i]:0:8}" "$status_short" "${ver_disp:0:8}" >/dev/tty
    fi
  done

  # Render Live Master-Detail Preview Pane for Currently Focused Tool
  _render_live_detail "$cursor"

  _tui_draw_footer "[↑/↓, k/j] Navigate  [Space] Toggle  [a] Toggle All  [i/Enter] Install  [u] Update  [d] Remove  [q/Esc] Quit"

  action=""
  _tui_read_key action

  case "$action" in
    REDRAW)
      continue
      ;;
    UP)
      if (( cursor > 0 )); then cursor=$((cursor - 1)); else cursor=$((item_count - 1)); fi
      ;;
    DOWN)
      if (( cursor < item_count - 1 )); then cursor=$((cursor + 1)); else cursor=0; fi
      ;;
    SPACE)
      selected[cursor]=$(( 1 - selected[cursor] ))
      ;;
    ALL)
      all_on=1
      for ((i=0; i<item_count; i++)); do
        (( selected[i] == 0 )) && { all_on=0; break; }
      done
      for ((i=0; i<item_count; i++)); do
        selected[i]=$(( 1 - all_on ))
      done
      ;;
    INSTALL|ENTER)
      _action_install
      _refresh_inventory
      ;;
    UPDATE)
      _action_update
      _refresh_inventory
      ;;
    DELETE)
      _action_delete
      _refresh_inventory
      ;;
    INFO)
      # In live-detail mode, info key is a convenient no-op or refresh
      ;;
    QUIT|ESC)
      break
      ;;
  esac
done

_tui_exit
printf "\nClosed ZenCLI Tools Notebook.\n"
