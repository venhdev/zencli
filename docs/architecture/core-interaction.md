---
title: Core Interaction Primitives
description: Architecture specification for terminal interaction primitives (TUI selectors, pickers, confirmation gates, and TTY lifecycle).
status: active
created: 2026-10-17
updated: 2026-10-17
---

# Core Interaction Primitives

Standardized interactive patterns across dotfiles (`core/00-shell-lib.sh`, `install.sh`, and module helpers).

## 1. Primitives Matrix

| Primitive | Context | Input Controls | Output Contract | Non-TTY / Fallback |
| --- | --- | --- | --- | --- |
| **TUI Multi-Select** | Module & tool installers | `[↑/↓]` `[j/k]` nav, `[Space]` toggle, `[a]` all, `[Enter]` ok, `[q]` cancel | State array / selection list | `-a`/`--all` or pre-selected defaults |
| **TUI Single-Select** | Key & path selectors | `[↑/↓]` `[j/k]` nav, `[Enter]` confirm, `[q]` cancel | String value or `""` (None) | Pre-detected default or abort |
| **CLI Picker (`_pick_one`)** | Interactive shell helpers | Numeric index (`1-N`) or item name; `[Enter]` default | Selected item to stdout | Returns single candidate |
| **CLI Multi-Picker (`_pick_many`)** | ADB / multi-target | Space-separated indices (`1 2 4`) | Selected items (newline-delimited) | Returns single candidate |
| **History Search (`h`)** | Interactive shell history | Keyword or limit (`h [query] [limit]`, default 10) | Formatted matching history entries | Prints matching lines to stdout |
| **Confirm Gate (`_confirm`)** | Pre-execution safety | `[y/N]` or `[Y/n]` via `read -rp` | Return code `0` (yes) / `1` (no) | Fails safe (aborts) |
| **Installer Confirm (`prompt_yes_no`)** | Final install gate | Explicit `[y/n]`; Enter re-prompts | Return code `0` (yes) / `1` (no) | Re-prompts until explicit y/n or cancel |
| **Command Runner (`_run_confirm`)** | Execution logging | Echo command `▶ ...`, `_confirm`, log metadata (status, dur, cwd) to state file, exec | Command execution or abort | Requires explicit confirmation |
| **Command Log & Rerun (`cmdlog` / `clog` / `cr`)** | Audit trail & rerun | View, search keyword, filter by CWD (`-d`), interactive rerun, edit-before-run (`-e`), clip | Interactive menu or direct execution | Fallback to tabular list |

## 2. Terminal Lifecycle Contract

```text
[Init / Preflight]
  ├── Detect TTY: can_prompt_interactively (exec 3<>/dev/tty)
  ├── Hide Cursor: tput civis >/dev/tty 2>/dev/null || printf "\033[?25l" >/dev/tty
  └── Install Traps: trap restore_cursor EXIT; trap handle_cancel INT TERM (exit 130)

[Render Loop]
  ├── Clear Screen: printf "\033[H\033[2J" >/dev/tty
  ├── Keypress Read: IFS= read -rsn1 key < /dev/tty
  └── Escape Handling: read -rsn2 -t 0.1 for arrow sequences ([A, [B) or j/k

[Teardown / Restore]
  └── Restore Cursor: tput cnorm >/dev/tty 2>/dev/null || printf "\033[?25h" >/dev/tty
```

### Engine Signatures
- `_tui_select_one <title> <subtitle> <selected_var> <items...>`: Single-select TUI menu. Returns chosen index in `selected_var`.
- `_tui_select_many <title> <subtitle> <state_array_ref> <has_toggle_all> <labels...>`: Multi-select checkbox TUI. Mutates `state_array_ref` in-place.

## 3. Governance Invariants

1. **Explicit TTY Isolation**: Interactive prompts must explicitly read/write to `/dev/tty` so scripts function when piped into bash (`curl ... | bash`).
2. **Safe Defaults**: Any destructive, state-mutating, or Windows-integration prompt must provide an explicit `[None]` / skip path and fail closed on abort.
3. **Audit Trail**: Any execution gated by `_run_confirm` must append timestamped, shell-quoted invocations along with execution status, duration, and working directory to `$_CMD_LOG` (`~/.local/state/zen/commands.log`), accessible and actionable via `cmdlog` / `clog` and `cr`.
4. **Cross-Platform Primitives**: System-dependent operations (`clip`, `open_target`, `pkg`, `svc`) must be invoked via standard abstraction shims, ensuring identical behavioral contracts across Linux, macOS (Darwin), and Windows (PowerShell/WSL/Git Bash).
