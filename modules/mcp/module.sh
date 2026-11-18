# MCP (MODEL CONTEXT PROTOCOL) AI CLIENT INTEGRATION MODULE
# Orchestrates MCP configurations for: opencode, agy, claude, codex, cursor
# Reference SSOT: https://github.com/venhdev/zenforge/blob/main/MCP.md

_zen_get_mcp_manager() {
  local root="${DOTFILES:-$(_get_zen_root 2>/dev/null || echo "$HOME/.config/dotfiles")}"
  if [[ -f "$root/modules/mcp/mcp-manager.py" ]]; then
    echo "$root/modules/mcp/mcp-manager.py"
    return 0
  fi
  local current_dir
  current_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || true)"
  if [[ -f "$current_dir/mcp-manager.py" ]]; then
    echo "$current_dir/mcp-manager.py"
    return 0
  fi
  return 1
}

_zen_get_mcp_tui() {
  local root="${DOTFILES:-$(_get_zen_root 2>/dev/null || echo "$HOME/.config/dotfiles")}"
  if [[ -f "$root/modules/mcp/mcp-tui.sh" ]]; then
    echo "$root/modules/mcp/mcp-tui.sh"
    return 0
  fi
  local current_dir
  current_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || true)"
  if [[ -f "$current_dir/mcp-tui.sh" ]]; then
    echo "$current_dir/mcp-tui.sh"
    return 0
  fi
  return 1
}

_zen_cmd_mcp() {
  if [[ "${1:-}" == "tui" ]]; then
    shift
    local tui_script
    tui_script="$(_zen_get_mcp_tui)"
    if [[ -z "$tui_script" || ! -f "$tui_script" ]]; then
      echo "❌ Error: MCP TUI script not found (expected at modules/mcp/mcp-tui.sh)" >&2
      return 1
    fi
    bash "$tui_script" "$@"
    return $?
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ Error: 'python3' is required to manage MCP configurations." >&2
    return 1
  fi

  local mgr
  mgr="$(_zen_get_mcp_manager)"
  if [[ -z "$mgr" || ! -f "$mgr" ]]; then
    echo "❌ Error: MCP manager script not found (expected at modules/mcp/mcp-manager.py)" >&2
    return 1
  fi

  python3 "$mgr" "$@"
}

# Terminal Shorthand Helpers & Aliases
zenmcp() {
  _zen_cmd_mcp "$@"
}

alias zmcp='zen mcp'                                       # Unified AI Agent MCP orchestrator
