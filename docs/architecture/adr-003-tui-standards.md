---
title: "ADR-003: Unified Terminal User Interface (TUI) Standards"
description: Architecture Decision Record defining unified TUI rules, Alternate Screen Buffer invariants, raw mode event handling, and standardized selection primitives across ZenCLI.
status: active
created: 2026-11-02
updated: 2026-11-02
---

# ADR-003: Unified Terminal User Interface (TUI) Standards

## 1. Context & Problem Statement

ZenCLI previously featured two diverging interactive terminal paradigms:
1. **`zen tui` (Toolchain Manager)**: Sourced `core/05-tui-lib.sh`, entered the xterm Alternate Screen Buffer (`\033[?1049h`), set terminal raw mode (`stty -echo -icanon min 1 time 0`), utilized a zero-fork reactive keyboard reader (`_tui_read_key`), and cleaned up automatically upon exit, leaving the terminal scrollback completely untouched.
2. **`zen setup` (`install.sh`)**: Relied on legacy ANSI screen clears (`\033[H\033[2J`) directly on the primary screen buffer, invoked high-latency reads (`read -rsn1` followed by `read -rsn2 -t 0.1`), and rendered inline borders that flickered and cluttered the user's shell scrollback history after completion.

This divergence created an inconsistent developer experience, introduced maintenance overhead across duplicate menu loops, and polluted terminal sessions during automated or semi-interactive installations.

## 2. Decision

ZenCLI mandates a single authoritative interaction standard codified in `core/05-tui-lib.sh`. All full-screen interactive menus across ZenCLI (`zen tui`, `zen setup`, and future wizards) must conform to the **7 TUI Architectural Invariants** and utilize standard selection engines.

## 3. The 7 TUI Architectural Invariants

### Invariant 1: Alternate Screen Buffer Lifecycle
All interactive full-screen experiences must initialize the Alternate Screen Buffer on entry and reliably restore the primary buffer on exit:
- **Enter**: `printf "\033[?1049h\033[?25l" >/dev/tty` (activate alternate buffer, hide cursor).
- **Exit**: `printf "\033[?25h\033[?1049l" >/dev/tty` (restore cursor, deactivate alternate buffer).
- **Safety Trap**: Robust traps on `EXIT`, `INT`, and `TERM` ensure the terminal cursor and buffer are restored even if the process is killed unexpectedly. Zero visual artifacts or cleared lines may bleed into the caller's terminal scrollback.

### Invariant 2: Zero-Fork Event Loop & In-Memory Mutation
Keypress handling and view rendering must run entirely in pure Bash without spawning subshells (`$(...)`) or invoking external binaries (`awk`, `sed`, `cut`, `dd`):
- **Raw Mode**: `stty -echo -icanon min 1 time 0` configured once upon entry.
- **Normalized Key Parser**: `_tui_read_key` decodes multi-byte ANSI escape sequences (Arrow keys, Esc, Home, End) with zero perceptible latency and maps them to canonical event tokens (`UP`, `DOWN`, `LEFT`, `RIGHT`, `ENTER`, `SPACE`, `QUIT`, `ESC`, `ALL`, or `CHAR:<c>`).
- **In-Memory String Helpers**: Primitives `_tui_repeat_char` and `_tui_truncate` accept an optional `out_var` parameter to assign results directly in caller memory via `printf -v "$out_var"` with zero subshell process forks.

### Invariant 3: Visual Design Tokens & Palette
All TUI components must use unified ANSI styling tokens defined in `core/05-tui-lib.sh`:
- **Primary / Brand**: `_TUI_CYAN` (`\033[36m`), `_TUI_BLUE` (`\033[34m`).
- **Success / Selection**: `_TUI_GREEN` (`\033[32m`), `_TUI_BOLD` (`\033[1m`).
- **Warning / Action**: `_TUI_YELLOW` (`\033[33m`).
- **Muted / Subtitles**: `_TUI_GRAY` (`\033[90m`), `_TUI_DIM` (`\033[2m`).
- **Surface Borders**: Unicode box-drawing characters (`┌`, `┐`, `└`, `┘`, `─`, `│`, `├`, `┤`).

### Invariant 4: Border Non-Wrapping Invariant
No rendered border or text line may exceed the active terminal width:
- **Dynamic Sizing**: Lines and columns are recalculated dynamically via `_tui_update_dimensions` (using `stty size` or `tput`, clamped between 36 and 80 columns).
- **Boundary Constraint**: Width is strictly clamped to `max_w = cols - 4`.
- **Text Truncation**: Strings exceeding `max_w - padding` must be truncated with an ellipsis (`...`) via `_tui_truncate` to prevent horizontal line-wrapping artifacts.

### Invariant 5: Modal Box Protocol
Confirmations, alerts, and help screens must be rendered as centered modal dialogs overlaying the current view:
- **Engine**: `_tui_modal_box` and `_tui_modal_confirm` handle calculation of vertical and horizontal centering.
- **Backdrop**: Modals draw clear background borders with distinct highlight colors.

### Invariant 6: Universal Keybindings
All interactive menus must adhere to standard navigation bindings:
- **Direct Jump**: `1`–`9` (Jump directly to item `[1]`–`[9]`), `0` (Jump to item `[10]` where total items >= 10).
- **Navigation**: `↑` / `k` (Move Up), `↓` / `j` (Move Down).
- **Selection**: `Space` (Toggle checkbox), `a` (Toggle All where applicable).
- **Confirmation**: `Enter` (Submit / Confirm).
- **Cancellation**: `q` or `Esc` (Abort / Exit cleanly with status 130).

### Invariant 7: Fallback & Non-Interactive Safety
All TUI engines must gracefully detect headless or non-interactive environments:
- **Inspection**: `_tui_is_interactive` validates that file descriptors 0 and 1 (or `/dev/tty`) are attached to an interactive terminal.
- **Bypass**: If executed in CI, piped streams (`curl ... | bash`), or scripts without a TTY, TUI functions must return immediately with exit code `0` and preserve default configuration states without hanging.

## 4. Authoritative Primitive APIs

### `_tui_select_one`
Single-select interactive menu.
```bash
_tui_select_one "$title" "$subtitle" selected_index "${candidates[@]}"
```
- Sets `selected_index` (by reference variable name) to the 0-based index of the chosen option.
- Restores alternate buffer upon Enter.
- Invokes `handle_cancel` or returns `130` on Quit/Esc.

### `_tui_select_many`
Multi-select checkbox menu.
```bash
_tui_select_many "$title" "$subtitle" state_array_ref "$has_toggle_all" "${labels[@]}"
```
- Mutates array `state_array_ref` in-place (`0` for unchecked, `1` for checked).
- Supports optional `"Toggle All"` synthetic item at index 0 when `has_toggle_all=1`.

## 5. Consequences & Status

- **Status**: Implemented & Enforced.
- **Refactored**: `install.sh` has been refactored to eliminate 145 lines of legacy console-clearing code, standardizing completely on `_tui_select_one` and `_tui_select_many`.
- **Terminal State**: `zen setup` and `zen tui` now share the exact same clean lifecycle, zero screen flicker, and leave zero scrollback clutter.
