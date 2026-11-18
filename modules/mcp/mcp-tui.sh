#!/usr/bin/env bash
# ==============================================================================
# modules/mcp/mcp-tui.sh - ZenCLI Universal MCP Orchestrator Native TUI Dashboard
# ==============================================================================
# Pure-Bash, zero-fork interactive dashboard connecting to core/05-tui-lib.sh.
# Manages Model Context Protocol configurations across AI clients:
# OpenCode, Antigravity, Claude Code, Codex CLI, Cursor IDE.
# ==============================================================================

set -uo pipefail

_resolve_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P 2>/dev/null || true)"
  if [[ -f "$dir/core/05-tui-lib.sh" ]]; then
    echo "$dir"
    return 0
  fi
  if [[ -n "${DOTFILES:-}" && -f "$DOTFILES/core/05-tui-lib.sh" ]]; then
    echo "$DOTFILES"
    return 0
  fi
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
}

_DOTFILES_ROOT="$(_resolve_root)"
_MGR_PY="$_DOTFILES_ROOT/modules/mcp/mcp-manager.py"

if [[ -f "$_DOTFILES_ROOT/core/05-tui-lib.sh" ]]; then
  # shellcheck source=../../core/05-tui-lib.sh
  . "$_DOTFILES_ROOT/core/05-tui-lib.sh"
else
  echo "Error: core/05-tui-lib.sh not found." >&2
  exit 1
fi

# Fallback for non-interactive environments
if ! [ -t 0 ] || ! [ -t 1 ] || ! _tui_is_interactive; then
  python3 "$_MGR_PY" status
  exit $?
fi

# ==============================================================================
# STATE & CACHED DATA
# ==============================================================================
declare -a CLIENT_KEYS=("opencode" "agy" "claude" "codex" "cursor")
declare -a CLIENT_NAMES=("OpenCode" "Antigravity" "Claude Code" "Codex CLI" "Cursor IDE")
declare -a CLIENT_STATUSES=()
declare -a CLIENT_SERVERS=()
declare -a CLIENT_TRANSPORTS=()
declare -a CLIENT_COMMANDS=()
declare -a CLIENT_ARGS=()
declare -a CLIENT_ENVS=()
declare -a CLIENT_WORKSPACES=()
declare -a CLIENT_PATHS=()
declare -a CLIENT_BIN_EXISTS=()

_flash_msg=""
_flash_color="${_TUI_GREEN:-}"

_set_flash() {
  _flash_msg="$1"
  _flash_color="${2:-${_TUI_GREEN:-}}"
}

_refresh_audit_data() {
  local json_raw
  json_raw="$(python3 "$_MGR_PY" check all --json 2>/dev/null || echo "[]")"
  
  CLIENT_STATUSES=()
  CLIENT_SERVERS=()
  CLIENT_TRANSPORTS=()
  CLIENT_COMMANDS=()
  CLIENT_ARGS=()
  CLIENT_ENVS=()
  CLIENT_WORKSPACES=()
  CLIENT_PATHS=()
  CLIENT_BIN_EXISTS=()

  # Parse JSON into bash-friendly unit-separated stream
  local tsv_stream
  tsv_stream="$(python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
    order = ["opencode", "agy", "claude", "codex", "cursor"]
    lookup = {item["client"]: item for item in data}
    for k in order:
        it = lookup.get(k, {})
        status = it.get("status", "NOT_CONFIGURED") or "NOT_CONFIGURED"
        server = it.get("server_name", "zenf") or "zenf"
        trans = it.get("transport", "-") or "-"
        cmd = it.get("binary_path", "-") or "-"
        args = " ".join(it.get("args", [])) or "-"
        env_map = json.dumps(it.get("env", {}))
        ws = it.get("workspace", "-") or "-"
        path = it.get("config_path", "-") or "-"
        bin_ex = "1" if it.get("binary_exists") else "0"
        print("\x1f".join([status, server, trans, cmd, args, env_map, ws, path, bin_ex]))
except Exception:
    pass
' "$json_raw" 2>/dev/null)"

  local line idx=0
  while IFS=$'\x1f' read -r status server trans cmd args env_map ws path bin_ex; do
    CLIENT_STATUSES[idx]="${status:-NOT_CONFIGURED}"
    CLIENT_SERVERS[idx]="${server:-zenf}"
    CLIENT_TRANSPORTS[idx]="${trans:--}"
    CLIENT_COMMANDS[idx]="${cmd:--}"
    CLIENT_ARGS[idx]="${args:--}"
    CLIENT_ENVS[idx]="${env_map:-"{}"}"
    CLIENT_WORKSPACES[idx]="${ws:--}"
    CLIENT_PATHS[idx]="${path:--}"
    CLIENT_BIN_EXISTS[idx]="${bin_ex:-0}"
    (( idx++ ))
  done <<< "$tsv_stream"
}

_render_detail_box() {
  local idx="$1"
  _tui_update_dimensions
  local cols="${_TUI_COLS:-80}"
  local lines="${_TUI_LINES:-24}"

  if (( lines < 16 )); then
    return 0
  fi

  local name="${CLIENT_NAMES[idx]}"
  local key="${CLIENT_KEYS[idx]}"
  local status="${CLIENT_STATUSES[idx]:-NOT_CONFIGURED}"
  local server="${CLIENT_SERVERS[idx]:-zenf}"
  local trans="${CLIENT_TRANSPORTS[idx]:--}"
  local cmd="${CLIENT_COMMANDS[idx]:-}"
  local args="${CLIENT_ARGS[idx]:-}"
  local env_map="${CLIENT_ENVS[idx]:-"{}"}"
  local ws="${CLIENT_WORKSPACES[idx]:-}"
  local path="${CLIENT_PATHS[idx]:-}"
  local bin_ex="${CLIENT_BIN_EXISTS[idx]:-0}"

  local width=$(( cols - 4 ))
  (( width > 84 )) && width=84
  (( width < 40 )) && return 0
  local inner_w=$(( width - 4 ))

  printf "\n" >/dev/tty
  local title_part="┌─[ CLIENT & SERVER INSPECTOR: $name ]"
  local pad_len=$(( width - ${#title_part} - 1 ))
  (( pad_len < 0 )) && pad_len=0
  local top_dashes=""
  _tui_repeat_char "─" "$pad_len" top_dashes
  printf "${_TUI_CYAN}${_TUI_BOLD}%s%s┐${_TUI_RESET}\n" "$title_part" "$top_dashes" >/dev/tty

  local home="$HOME"
  local disp_path="$path"
  if [[ "$disp_path" == "$home"* ]]; then
    disp_path="~${disp_path#"$home"}"
  fi

  local status_fmt=""
  case "$status" in
    CONFIGURED)
      status_fmt="${_TUI_GREEN}✔ ACTIVE & CONFIGURED${_TUI_RESET}"
      ;;
    ALREADY_CONFIGURED)
      status_fmt="${_TUI_GREEN}✔ CONFIGURED${_TUI_RESET}"
      ;;
    BINARY_MISSING)
      status_fmt="${_TUI_YELLOW}⚠ CONFIGURED (BINARY MISSING ON DISK)${_TUI_RESET}"
      ;;
    FILE_MISSING)
      status_fmt="${_TUI_GRAY}○ CONFIG FILE NOT CREATED YET${_TUI_RESET}"
      ;;
    *)
      status_fmt="${_TUI_RED}✗ NOT CONFIGURED${_TUI_RESET}"
      ;;
  esac

  local disp_cmd="${cmd:-None}"
  [[ "$disp_cmd" == "-" ]] && disp_cmd="None"
  local disp_args="${args:-None}"
  [[ "$disp_args" == "-" ]] && disp_args="None"
  local disp_ws="${ws:--}"
  local disp_env="${env_map:-"{}"}"
  [[ "$disp_env" == "{}" || "$disp_env" == "-" ]] && disp_env="None"

  local lines_to_print=(
    "AI Client Identifier : $key ($name)"
    "Configuration File   : $disp_path"
    "Active MCP Server     : $server"
    "Transport Mechanism   : $trans"
    "Workspace Binding    : $disp_ws"
    "Executable Command   : $disp_cmd"
    "Command Arguments    : $disp_args"
    "Environment Injected : $disp_env"
    "Health Status        : $status_fmt"
  )

  for line in "${lines_to_print[@]}"; do
    local trunc_line=""
    _tui_truncate "$line" "$inner_w" trunc_line
    printf "${_TUI_CYAN}│${_TUI_RESET} %-*s ${_TUI_CYAN}│${_TUI_RESET}\n" "$inner_w" "$trunc_line" >/dev/tty
  done

  local bot_dashes=""
  _tui_repeat_char "─" "$(( width - 2 ))" bot_dashes
  printf "${_TUI_CYAN}└%s┘${_TUI_RESET}\n" "$bot_dashes" >/dev/tty
}

_mcp_tui_add_preset_flow() {
  local client_idx="$1"
  local client_key="${CLIENT_KEYS[client_idx]}"
  local client_name="${CLIENT_NAMES[client_idx]}"

  local preset_choices=(
    "sqlite     - Official SQLite MCP (PyPI: mcp-server-sqlite via uvx)"
    "github     - Official GitHub MCP (npm: @modelcontextprotocol/server-github via npx)"
    "fetch      - Web content fetcher MCP (PyPI: mcp-server-fetch via uvx)"
    "filesystem - Local filesystem MCP (npm: @modelcontextprotocol/server-filesystem via npx)"
    "postgres   - PostgreSQL database MCP (npm: @modelcontextprotocol/server-postgres via npx)"
    "zenforge   - ZenForge tracking plane & state machine (native: zenf)"
  )

  local chosen_preset_idx=0
  if ! _tui_select_one "SELECT MCP PRESET TO CONFIGURE" "Target Client: $client_name ($client_key)" preset_choices chosen_preset_idx; then
    return 0
  fi

  local preset_id=""
  case "$chosen_preset_idx" in
    0) preset_id="sqlite" ;;
    1) preset_id="github" ;;
    2) preset_id="fetch" ;;
    3) preset_id="filesystem" ;;
    4) preset_id="postgres" ;;
    5) preset_id="zenforge" ;;
  esac

  local val_param=""
  local val_server=""
  local cmd_args=()
  local review_lines=()

  case "$preset_id" in
    sqlite)
      if ! _tui_modal_input "STEP 1/2: DATABASE PATH" "Enter path to SQLite database file (.db/.sqlite):" "$HOME/.local/share/mcp/default.db" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_param; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      if ! _tui_modal_input "STEP 2/2: CONFIG SERVER KEY" "Identifier name in AI client config:" "sqlite" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_server; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      cmd_args=("--db" "$val_param" "-s" "${val_server:-sqlite}")
      review_lines=(
        "Client Target  : $client_name ($client_key)"
        "Preset Package : PyPI: mcp-server-sqlite (uvx)"
        "Database Path  : $val_param"
        "Server Key     : ${val_server:-sqlite}"
        ""
        "A backup (<config>.{yyMMddhhmm}.bak) will be created automatically."
      )
      ;;

    github)
      local def_token="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
      if ! _tui_modal_input "STEP 1/2: GITHUB ACCESS TOKEN" "Enter Personal Access Token (classic, repo scope):" "$def_token" 1 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_param; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      if ! _tui_modal_input "STEP 2/2: CONFIG SERVER KEY" "Identifier name in AI client config:" "github" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_server; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      if [[ -n "$val_param" ]]; then
        cmd_args=("--token" "$val_param" "-s" "${val_server:-github}")
      else
        cmd_args=("-s" "${val_server:-github}")
      fi
      local token_disp="[Ambient Environment]"
      [[ -n "$val_param" ]] && token_disp="[Explicit Token Provided]"
      review_lines=(
        "Client Target  : $client_name ($client_key)"
        "Preset Package : npm: @modelcontextprotocol/server-github (npx)"
        "Auth Token     : $token_disp"
        "Server Key     : ${val_server:-github}"
        ""
        "A backup (<config>.{yyMMddhhmm}.bak) will be created automatically."
      )
      ;;

    filesystem)
      if ! _tui_modal_input "STEP 1/2: ALLOWED DIRECTORY" "Root folder the AI agent is permitted to access:" "$HOME" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_param; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      if ! _tui_modal_input "STEP 2/2: CONFIG SERVER KEY" "Identifier name in AI client config:" "filesystem" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_server; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      cmd_args=("--path" "$val_param" "-s" "${val_server:-filesystem}")
      review_lines=(
        "Client Target  : $client_name ($client_key)"
        "Preset Package : npm: @modelcontextprotocol/server-filesystem (npx)"
        "Allowed Folder : $val_param"
        "Server Key     : ${val_server:-filesystem}"
        ""
        "A backup (<config>.{yyMMddhhmm}.bak) will be created automatically."
      )
      ;;

    fetch)
      if ! _tui_modal_input "STEP 1/1: CONFIG SERVER KEY" "Identifier name in AI client config:" "fetch" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_server; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      cmd_args=("-s" "${val_server:-fetch}")
      review_lines=(
        "Client Target  : $client_name ($client_key)"
        "Preset Package : PyPI: mcp-server-fetch (uvx)"
        "Server Key     : ${val_server:-fetch}"
        ""
        "A backup (<config>.{yyMMddhhmm}.bak) will be created automatically."
      )
      ;;

    postgres)
      if ! _tui_modal_input "STEP 1/2: POSTGRESQL URI" "Connection URI (postgresql://user:pass@host:5432/db):" "postgresql://localhost:5432/mydb" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_param; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      if ! _tui_modal_input "STEP 2/2: CONFIG SERVER KEY" "Identifier name in AI client config:" "postgres" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_server; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      cmd_args=("--conn" "$val_param" "-s" "${val_server:-postgres}")
      review_lines=(
        "Client Target  : $client_name ($client_key)"
        "Preset Package : npm: @modelcontextprotocol/server-postgres (npx)"
        "Connection URI : $val_param"
        "Server Key     : ${val_server:-postgres}"
        ""
        "A backup (<config>.{yyMMddhhmm}.bak) will be created automatically."
      )
      ;;

    zenforge)
      if ! _tui_modal_input "STEP 1/2: ZENFORGE WORKSPACE" "Workspace name for ZenForge tracking plane:" "default" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_param; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      if ! _tui_modal_input "STEP 2/2: CONFIG SERVER KEY" "Identifier name in AI client config:" "zenf" 0 "[Enter] Confirm   [Backspace] Edit   [Esc] Cancel" val_server; then
        _set_flash "Configuration wizard cancelled." "${_TUI_YELLOW}"
        return 0
      fi
      cmd_args=("--workspace" "$val_param" "-s" "${val_server:-zenf}")
      review_lines=(
        "Client Target  : $client_name ($client_key)"
        "Preset Package : native: zenf"
        "Workspace Name : $val_param"
        "Server Key     : ${val_server:-zenf}"
        ""
        "A backup (<config>.{yyMMddhhmm}.bak) will be created automatically."
      )
      ;;
  esac

  # Final Review & Confirmation Modal
  if _tui_modal_confirm "REVIEW & APPLY CONFIGURATION" review_lines "[Y/Enter] Install & Apply Configuration   [n/Esc/q] Cancel"; then
    local out
    out="$(python3 "$_MGR_PY" add "$preset_id" -c "$client_key" "${cmd_args[@]}" 2>&1)" || true
    _set_flash "✔ Configured $preset_id for $client_name" "${_TUI_GREEN}"
    _refresh_audit_data
  else
    _set_flash "Configuration aborted." "${_TUI_YELLOW}"
  fi
}

_mcp_tui_remove_server_flow() {
  local client_idx="$1"
  local client_key="${CLIENT_KEYS[client_idx]}"
  local client_name="${CLIENT_NAMES[client_idx]}"
  local server_name="${CLIENT_SERVERS[client_idx]:-zenf}"
  local status="${CLIENT_STATUSES[client_idx]:-NOT_CONFIGURED}"

  if [[ "$status" != "CONFIGURED" && "$status" != "ALREADY_CONFIGURED" && "$status" != "BINARY_MISSING" ]]; then
    _set_flash "Notice: No active MCP server to remove for $client_name." "${_TUI_YELLOW}"
    return 0
  fi

  local confirm_lines=(
    "Client Target : $client_name ($client_key)"
    "Server Name   : $server_name"
    ""
    "Are you sure you want to remove this MCP server?"
    "A backup (<config>.{yyMMddhhmm}.bak) will be created automatically."
  )

  if _tui_modal_confirm "CONFIRM SERVER REMOVAL" confirm_lines "[Y/Enter] Confirm Removal   [n/Esc/q] Cancel"; then
    local out
    out="$(python3 "$_MGR_PY" remove "$server_name" -c "$client_key" 2>&1)" || true
    _set_flash "✔ Removed server '$server_name' from $client_name" "${_TUI_GREEN}"
    _refresh_audit_data
  fi
}

_mcp_tui_toggle_zenforge() {
  local client_idx="$1"
  local client_key="${CLIENT_KEYS[client_idx]}"
  local client_name="${CLIENT_NAMES[client_idx]}"
  local status="${CLIENT_STATUSES[client_idx]:-NOT_CONFIGURED}"

  if [[ "$status" == "CONFIGURED" || "$status" == "ALREADY_CONFIGURED" ]]; then
    _set_flash "Client $client_name is already configured. Press [d] to remove or [a] to add." "${_TUI_YELLOW}"
    return 0
  fi

  local out
  out="$(python3 "$_MGR_PY" add zenforge -c "$client_key" 2>&1)" || true
  _set_flash "✔ Configured ZenForge for $client_name" "${_TUI_GREEN}"
  _refresh_audit_data
}

# ==============================================================================
# MAIN EVENT LOOP
# ==============================================================================
_mcp_tui_main() {
  _tui_enter
  trap '_tui_exit' EXIT INT TERM

  _refresh_audit_data
  local cursor=0
  local total=${#CLIENT_KEYS[@]}

  while true; do
    _tui_clear
    _tui_update_dimensions
    local max_w="${_TUI_COLS:-80}"

    _tui_draw_header "ZENCLI: MCP ORCHESTRATOR" "Universal Multi-Client AI Agent Integration Studio"

    if [[ -n "$_flash_msg" ]]; then
      printf " %b%s%b\n\n" "$_flash_color" "$_flash_msg" "${_TUI_RESET}" >/dev/tty
    else
      printf " Live audit matrix for AI Agent MCP configurations:\n\n" >/dev/tty
    fi

    # Render Client Rows
    for (( i = 0; i < total; i++ )); do
      local k="${CLIENT_KEYS[i]}"
      local n="${CLIENT_NAMES[i]}"
      local s="${CLIENT_STATUSES[i]:-NOT_CONFIGURED}"
      local srv="${CLIENT_SERVERS[i]:--}"
      local ws="${CLIENT_WORKSPACES[i]:-}"
      local trans="${CLIENT_TRANSPORTS[i]:--}"

      local badge=""
      case "$s" in
        CONFIGURED|ALREADY_CONFIGURED)
          badge="${_TUI_GREEN}[✔ CONFIGURED]${_TUI_RESET}"
          ;;
        BINARY_MISSING)
          badge="${_TUI_YELLOW}[⚠ BINARY MISSING]${_TUI_RESET}"
          ;;
        FILE_MISSING)
          badge="${_TUI_GRAY}[○ NO FILE]${_TUI_RESET}"
          ;;
        *)
          badge="${_TUI_RED}[✗ NOT SET]${_TUI_RESET}"
          ;;
      esac

      local info=""
      if [[ "$s" == "CONFIGURED" || "$s" == "ALREADY_CONFIGURED" || "$s" == "BINARY_MISSING" ]]; then
        info="Server: ${_TUI_BOLD}$srv${_TUI_RESET} ($trans)"
        [[ -n "$ws" ]] && info="$info [ws: $ws]"
      else
        info="${_TUI_GRAY}No server active${_TUI_RESET}"
      fi

      local prefix="   "
      if (( i == cursor )); then
        prefix="${_TUI_CYAN}${_TUI_BOLD} ❯ ${_TUI_RESET}"
        printf "%b${_TUI_BOLD}[%d] %-14s%b %-26b %b\n" "$prefix" "$((i + 1))" "$n" "${_TUI_RESET}" "$badge" "$info" >/dev/tty
      else
        printf "%b[%d] %-14s %-26b %b\n" "$prefix" "$((i + 1))" "$n" "$badge" "$info" >/dev/tty
      fi
    done

    # Render Inspector Box for currently highlighted client
    _render_detail_box "$cursor"

    # Render Command Footer
    _tui_draw_footer "[1-5] Jump  [↑/↓] Move  [Space] Config ZenForge  [a] Add Preset  [d] Delete  [r] Refresh  [q] Quit"

    # Wait for User Key Event
    local action=""
    _tui_read_key action

    _flash_msg="" # Reset flash after key press

    case "$action" in
      UP)
        (( cursor = (cursor - 1 + total) % total ))
        ;;
      DOWN)
        (( cursor = (cursor + 1) % total ))
        ;;
      1|2|3|4|5)
        local jump_idx=$(( action - 1 ))
        if (( jump_idx >= 0 && jump_idx < total )); then
          cursor=$jump_idx
        fi
        ;;
      SPACE)
        _mcp_tui_toggle_zenforge "$cursor"
        ;;
      a|A)
        _mcp_tui_add_preset_flow "$cursor"
        ;;
      d|D)
        _mcp_tui_remove_server_flow "$cursor"
        ;;
      r|R)
        _refresh_audit_data
        _set_flash "✔ Refreshed live MCP integration audit." "${_TUI_GREEN}"
        ;;
      q|Q|ESC)
        _tui_exit
        return 0
        ;;
    esac
  done
}

_mcp_tui_main "$@"
