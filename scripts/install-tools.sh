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
        i_at = t.get("installed_at") or t.get("updated_at") or "-"
        u_at = t.get("updated_at") or "-"
        print(f"{i_at}|{u_at}")
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
staged_actions=()

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

      # Auto-sync active installed tool into manifest ledger first
      local clean_origin="apt"
      [[ "$origin_label" == *"github"* ]] && clean_origin="github"
      _manifest_sync_tool "$cmd" "$clean_origin" "$apt_pkg" "${ver_str:--}" "$path_val" "$gh_repo"

      # Pre-cache manifest installed date once during inventory refresh
      local inst_date="-"
      local minfo
      minfo="$(_manifest_get_tool_info "$cmd" || true)"
      if [[ -n "$minfo" ]]; then
        inst_date="${minfo%%|*}"
      fi

      # Format ISO timestamp into clean human-readable date: 2026-11-02 01:12 UTC
      if [[ "$inst_date" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}) ]]; then
        inst_date="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} UTC"
      elif [[ "$inst_date" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        inst_date="${BASH_REMATCH[1]}"
      fi
      manifest_dates+=("$inst_date")
    fi

    # Maintain existing staged action or default to 0 (None)
    if [[ -z "${staged_actions[i]:-}" ]]; then
      staged_actions+=(0)
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

# ==============================================================================
# BATCH TRANSACTION MANAGER & SUDO PRE-WARMING
# ==============================================================================
_action_review_and_execute() {
  local apt_install=()
  local apt_install_indices=()
  local apt_update=()
  local apt_update_indices=()
  local apt_remove=()
  local apt_remove_indices=()

  local gh_install=()
  local gh_install_indices=()
  local gh_update=()
  local gh_update_indices=()
  local gh_remove=()
  local gh_remove_indices=()

  local total_staged=0

  for ((i=0; i<item_count; i++)); do
    local action="${staged_actions[i]:-0}"
    (( action == 0 )) && continue
    (( ++total_staged ))

    local c="${cmds[i]}"
    local pkg="${apt_pkgs[i]}"
    local repo="${gh_repos[i]}"
    local orig="${origins[i]}"

    case "$action" in
      1) # INSTALL
        if _is_in_apt "$pkg"; then
          apt_install+=("$pkg")
          apt_install_indices+=("$i")
        elif [[ -n "$repo" ]]; then
          gh_install+=("$c")
          gh_install_indices+=("$i")
        fi
        ;;
      2) # UPDATE
        if [[ "$orig" == *"apt"* ]] || _is_in_apt "$pkg"; then
          apt_update+=("$pkg")
          apt_update_indices+=("$i")
        elif [[ "$orig" == *"github"* && -n "$repo" ]]; then
          gh_update+=("$c")
          gh_update_indices+=("$i")
        fi
        ;;
      3) # REMOVE
        if [[ "$orig" == *"apt"* ]]; then
          apt_remove+=("$pkg")
          apt_remove_indices+=("$i")
        elif [[ "$orig" == *"github"* || "${paths[i]}" == "$HOME/.local/bin/"* ]]; then
          gh_remove+=("$c")
          gh_remove_indices+=("$i")
        fi
        ;;
    esac
  done

  # If queue is empty, trigger smart action for cursor tool
  if (( total_staged == 0 )); then
    if (( statuses[cursor] == 0 )); then
      staged_actions[cursor]=1
      if _is_in_apt "${apt_pkgs[cursor]}"; then
        apt_install+=("${apt_pkgs[cursor]}")
        apt_install_indices+=("$cursor")
      elif [[ -n "${gh_repos[cursor]}" ]]; then
        gh_install+=("${cmds[cursor]}")
        gh_install_indices+=("$cursor")
      fi
      total_staged=1
    else
      staged_actions[cursor]=2
      if [[ "${origins[cursor]}" == *"apt"* ]] || _is_in_apt "${apt_pkgs[cursor]}"; then
        apt_update+=("${apt_pkgs[cursor]}")
        apt_update_indices+=("$cursor")
      elif [[ -n "${gh_repos[cursor]}" ]]; then
        gh_update+=("${cmds[cursor]}")
        gh_update_indices+=("$cursor")
      fi
      total_staged=1
    fi
  fi

  local total_apt=$(( ${#apt_install[@]} + ${#apt_update[@]} + ${#apt_remove[@]} ))
  local total_gh=$(( ${#gh_install[@]} + ${#gh_update[@]} + ${#gh_remove[@]} ))

  # Build Review Modal summary lines
  local review_lines=(
    "TRANSACTION REVIEW: Staged operations to apply"
    ""
  )

  if (( ${#apt_install[@]} > 0 || ${#gh_install[@]} > 0 )); then
    local ins_list=("${apt_install[@]}" "${gh_install[@]}")
    review_lines+=("  [+ INSTALL] (${#ins_list[@]}): ${ins_list[*]}")
  fi

  if (( ${#apt_update[@]} > 0 || ${#gh_update[@]} > 0 )); then
    local upd_list=("${apt_update[@]}" "${gh_update[@]}")
    review_lines+=("  [^ UPDATE ] (${#upd_list[@]}): ${upd_list[*]}")
  fi

  if (( ${#apt_remove[@]} > 0 || ${#gh_remove[@]} > 0 )); then
    local rem_list=("${apt_remove[@]}" "${gh_remove[@]}")
    review_lines+=("  [- REMOVE ] (${#rem_list[@]}): ${rem_list[*]}")
  fi

  review_lines+=(
    ""
    "Privilege Execution Plan:"
  )
  if (( total_apt > 0 )); then
    review_lines+=(
      "  - System APT ($total_apt pkgs): Requires sudo"
      "    (Password authenticated once up front)"
    )
  fi
  if (( total_gh > 0 )); then
    review_lines+=(
      "  - User Binaries ($total_gh pkgs): ~/.local/bin (no sudo)"
    )
  fi

  review_lines+=(
    ""
    "Apply this transaction queue now?"
  )

  # Present Review Sheet Modal
  if ! _tui_modal_confirm "CONFIRM TRANSACTION" review_lines "[Y/Enter] Execute queue   [n/Esc/q] Return to edit"; then
    return 0
  fi

  # Execution Phase
  _tui_exit

  printf "\n${_TUI_CYAN}${_TUI_BOLD}=== ZENCLI BATCH TRANSACTION EXECUTION ===${_TUI_RESET}\n"

  # 1. Sudo Pre-warming if APT operations exist
  if (( total_apt > 0 )); then
    printf "\n${_TUI_CYAN}==> Pre-authenticating sudo credentials for APT operations...${_TUI_RESET}\n"
    if ! sudo -v; then
      printf "${_TUI_RED}Error: Sudo authentication failed. Transaction aborted.${_TUI_RESET}\n"
      printf "\n${_TUI_GRAY}Press Enter to return to ZenCLI Notebook...${_TUI_RESET}"
      read -r _ </dev/tty || true
      _tui_enter
      return 1
    fi
  fi

  # 2. Atomic APT Update & Install / Upgrade
  local apt_ops=("${apt_install[@]}" "${apt_update[@]}")
  if (( ${#apt_ops[@]} > 0 )); then
    printf "\n${_TUI_CYAN}==> Updating APT cache & installing/upgrading: %s...${_TUI_RESET}\n" "${apt_ops[*]}"
    sudo apt update && sudo apt install -y "${apt_ops[@]}"
    for idx in "${apt_install_indices[@]}" "${apt_update_indices[@]}"; do
      local c="${cmds[idx]}"
      local pkg="${apt_pkgs[idx]}"
      if command -v "$c" >/dev/null 2>&1; then
        _manifest_sync_tool "$c" "apt" "$pkg" "$(_get_tool_version "$c")" "$(command -v "$c")" "${gh_repos[idx]}"
      fi
    done
  fi

  # 3. Atomic APT Removal
  if (( ${#apt_remove[@]} > 0 )); then
    printf "\n${_TUI_YELLOW}==> Removing APT packages: %s...${_TUI_RESET}\n" "${apt_remove[*]}"
    sudo apt remove -y "${apt_remove[@]}"
    for idx in "${apt_remove_indices[@]}"; do
      local c="${cmds[idx]}"
      _manifest_remove_tool "$c"
    done
  fi

  # 4. GitHub Release Installs & Updates (Zero Sudo)
  for g_idx in "${gh_install_indices[@]}" "${gh_update_indices[@]}"; do
    _install_from_github "${cmds[g_idx]}" "${gh_repos[g_idx]}" "${asset_fmts[g_idx]}" "${bin_names[g_idx]}" "${descs[g_idx]}"
  done

  # 5. GitHub User Binary Removal (Zero Sudo)
  for g_idx in "${gh_remove_indices[@]}"; do
    local p="${paths[g_idx]}"
    local c="${cmds[g_idx]}"
    rm -f "$p"
    printf "${_TUI_GREEN}✔ Removed user binary: %s${_TUI_RESET}\n" "$p"
    _manifest_remove_tool "$c"
  done

  # Reset all staged actions upon completion
  for ((i=0; i<item_count; i++)); do
    staged_actions[i]=0
  done

  printf "\n${_TUI_GREEN}${_TUI_BOLD}✔ Transaction applied successfully.${_TUI_RESET}\n"
  printf "\n${_TUI_GRAY}Press Enter to return to ZenCLI Notebook...${_TUI_RESET}"
  read -r _ </dev/tty || true
  _refresh_inventory
  _tui_enter
}

# Dedicated Interactive Help Dialog
_action_show_help() {
  local help_lines=(
    "ZENCLI DEVELOPER TOOLS NOTEBOOK"
    ""
    "Staging & Queue Keybindings:"
    "  i, +       Stage tool for INSTALL  [+]"
    "  u, ^       Stage tool for UPDATE   [^]"
    "  d, -       Stage tool for REMOVE   [-]"
    "  Space      Smart toggle focused tool"
    "  a, A       Select all / Toggle all"
    "             (stages all if partial, clears if all)"
    "  c, C       Clear entire staging queue"
    "  m          Stage ALL missing tools [+]"
    ""
    "Execution & Transactions:"
    "  Enter      Review & Apply transaction"
    "             (Combines APT & GitHub into"
    "              a single atomic batch)"
    ""
    "Navigation & General:"
    "  ↑/↓, k/j   Navigate tools catalog"
    "  ?, h       Show this help dialog"
    "  q, Esc     Quit notebook"
  )
  _tui_modal_box "HELP & SHORTCUTS" help_lines
}

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

  local action_badge="None [ ]"
  case "${staged_actions[idx]:-0}" in
    1) action_badge="[+] INSTALL" ;;
    2) action_badge="[^] UPDATE" ;;
    3) action_badge="[-] REMOVE" ;;
  esac

  local detail_lines=(
    "Description       : $d"
    "Status            : $s"
    "Staged Intent     : $action_badge"
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
    local pad_spaces=$(( inner_width - ${#trunc_line} ))
    (( pad_spaces < 0 )) && pad_spaces=0
    local pad_str
    printf -v pad_str "%*s" "$pad_spaces" ""
    printf "${_TUI_CYAN}│${_TUI_RESET} %s%s ${_TUI_CYAN}│${_TUI_RESET}\n" "$trunc_line" "$pad_str" >/dev/tty
  done

  local bot_dashes
  bot_dashes="$(_tui_repeat_char "─" "$(( width - 2 ))")"
  printf "${_TUI_CYAN}└%s┘${_TUI_RESET}\n" "$bot_dashes" >/dev/tty
}

# ==============================================================================
# MAIN TUI INTERACTIVE LOOP
# ==============================================================================
cursor=0

_main_tui_loop() {
  _tui_enter

  while true; do
  _tui_clear
  _tui_update_dimensions
  cols="${_TUI_COLS:-80}"

  _tui_draw_header "ZENCLI: DEVELOPER TOOLS NOTEBOOK" "Developer Tool Ledger & Provisioning Manager"

  # Responsive Table Columns based on available width
  if (( cols >= 85 )); then
    printf "      %-10s %-13s %-10s %-15s %s\n" "COMMAND" "STATUS" "VERSION" "ORIGIN" "DESCRIPTION" >/dev/tty
    printf "      ───────    ───────────── ───────    ──────         ───────────\n" >/dev/tty
  elif (( cols >= 62 )); then
    printf "      %-10s %-13s %-10s %-15s\n" "COMMAND" "STATUS" "VERSION" "ORIGIN" >/dev/tty
    printf "      ───────    ───────────── ───────    ──────\n" >/dev/tty
  else
    printf "      %-7s   %-6s   %s\n" "COMMAND" "STATUS" "VER" >/dev/tty
    printf "      ───────   ──────   ───\n" >/dev/tty
  fi

  # Render Rows
  for ((i=0; i<item_count; i++)); do
    local badge
    case "${staged_actions[i]:-0}" in
      1) badge="${_TUI_GREEN}[+]${_TUI_RESET}" ;;
      2) badge="${_TUI_CYAN}[^]${_TUI_RESET}" ;;
      3) badge="${_TUI_RED}[-]${_TUI_RESET}" ;;
      *) badge="${_TUI_GRAY}[ ]${_TUI_RESET}" ;;
    esac

    if (( statuses[i] )); then
      status_disp="${_TUI_GREEN}Installed    ${_TUI_RESET}"
      status_short="${_TUI_GREEN}Inst  ${_TUI_RESET}"
    else
      status_disp="${_TUI_GRAY}Not Installed${_TUI_RESET}"
      status_short="${_TUI_GRAY}None  ${_TUI_RESET}"
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
      printf "%b%b %-10s %b %-10s %-15s %s\n" \
        "$prefix" "$badge" "${cmds[i]}" "$status_disp" "$ver_disp" "$orig_disp" "$desc_trunc" >/dev/tty
    elif (( cols >= 62 )); then
      printf "%b%b %-10s %b %-10s %-15s\n" \
        "$prefix" "$badge" "${cmds[i]}" "$status_disp" "$ver_disp" "$orig_disp" >/dev/tty
    else
      printf "%b%b %-7s   %b   %s\n" \
        "$prefix" "$badge" "${cmds[i]:0:7}" "$status_short" "${ver_disp:0:8}" >/dev/tty
    fi
  done

  # Render Live Master-Detail Preview Pane for Currently Focused Tool
  _render_live_detail "$cursor"

  # Dynamic Footer with Queue Status
  local q_ins=0 q_upd=0 q_del=0
  for ((i=0; i<item_count; i++)); do
    case "${staged_actions[i]:-0}" in
      1) (( ++q_ins )) ;;
      2) (( ++q_upd )) ;;
      3) (( ++q_del )) ;;
    esac
  done
  local q_tot=$(( q_ins + q_upd + q_del ))

  if (( q_tot > 0 )); then
    local q_parts=()
    (( q_ins > 0 )) && q_parts+=("${q_ins} ins")
    (( q_upd > 0 )) && q_parts+=("${q_upd} upd")
    (( q_del > 0 )) && q_parts+=("${q_del} del")
    local q_summary="${q_parts[*]}"
    q_summary="${q_summary// /, }"
    if (( cols >= 72 )); then
      _tui_draw_footer "QUEUE: $q_summary │ [Enter] Review & Apply │ [a] All │ [c] Clear"
    else
      _tui_draw_footer "QUEUE ($q_tot) │ [Enter] Apply │ [a] All │ [c] Clear"
    fi
  else
    if (( cols >= 76 )); then
      _tui_draw_footer "[↑/↓] Move  [i] Ins  [u] Upd  [d] Del  [a] All  [c] Clear  [?] Help  [q] Quit"
    elif (( cols >= 62 )); then
      _tui_draw_footer "[↑/↓] Move  [i] Ins  [u] Upd  [a] All  [c] Clear  [?] Help  [q] Quit"
    else
      _tui_draw_footer "[↑/↓] Move  [a] All  [c] Clear  [?] Help  [q] Quit"
    fi
  fi

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
      if (( staged_actions[cursor] > 0 )); then
        staged_actions[cursor]=0
      else
        if (( statuses[cursor] == 0 )); then
          staged_actions[cursor]=1
        else
          staged_actions[cursor]=2
        fi
      fi
      ;;
    INSTALL)
      if (( statuses[cursor] == 0 )); then
        staged_actions[cursor]=1
      else
        staged_actions[cursor]=2
      fi
      ;;
    UPDATE)
      if (( statuses[cursor] == 1 )); then
        staged_actions[cursor]=2
      else
        staged_actions[cursor]=1
      fi
      ;;
    DELETE)
      if (( statuses[cursor] == 1 )); then
        staged_actions[cursor]=3
      fi
      ;;
    MISSING)
      for ((i=0; i<item_count; i++)); do
        if (( statuses[i] == 0 )); then
          staged_actions[i]=1
        fi
      done
      ;;
    TOGGLE_ALL)
      local all_staged=1
      for ((i=0; i<item_count; i++)); do
        if (( staged_actions[i] == 0 )); then
          all_staged=0
          break
        fi
      done
      if (( all_staged )); then
        # When all are already staged, pressing 'a' clears all
        for ((i=0; i<item_count; i++)); do
          staged_actions[i]=0
        done
      else
        # When 0 or partially staged, pressing 'a' stages all
        for ((i=0; i<item_count; i++)); do
          if (( statuses[i] == 0 )); then
            staged_actions[i]=1
          else
            staged_actions[i]=2
          fi
        done
      fi
      ;;
    CLEAR)
      for ((i=0; i<item_count; i++)); do
        staged_actions[i]=0
      done
      ;;
    ENTER)
      _action_review_and_execute
      ;;
    INFO)
      _action_show_help
      ;;
    QUIT|ESC)
      break
      ;;
  esac
done

  _tui_exit
  printf "\nClosed ZenCLI Tools Notebook.\n"
}

_main_tui_loop
