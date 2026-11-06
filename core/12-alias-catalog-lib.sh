#!/usr/bin/env bash
# ==============================================================================
# core/12-alias-catalog-lib.sh - Zen Alias & Shortcut Catalog Engine
# ==============================================================================
# Discovers, categorizes, formats, and searches all active shell aliases,
# Git configuration shortcuts, and ZenCLI ecosystem utilities in the current OS.
# ==============================================================================

_zen_alias_catalog() {
  local query="${1:-}"
  [[ "$query" == "list" || "$query" == "all" ]] && query=""

  local dotfiles_root
  if declare -F _get_zen_root >/dev/null 2>&1; then
    dotfiles_root="$(_get_zen_root)"
  elif declare -F _get_dotfiles_root >/dev/null 2>&1; then
    dotfiles_root="$(_get_dotfiles_root)"
  else
    dotfiles_root="${ZENCLI_ROOT:-${ZENCLI_DIR:-${ZEN_ROOT:-${ZEN_DIR:-${ZEN:-${XDG_CONFIG_HOME:-$HOME/.config}/zencli}}}}}"
  fi

  local files=()
  [[ -f "$dotfiles_root/core/10-base-aliases.sh" ]] && files+=("$dotfiles_root/core/10-base-aliases.sh")
  for mod in "$dotfiles_root"/modules/*/module.sh; do
    [[ -f "$mod" ]] && files+=("$mod")
  done

  # 1. Collect active shell aliases from live shell session
  local active_aliases_tmp
  active_aliases_tmp="$(builtin alias -p 2>/dev/null || alias 2>/dev/null || true)"

  # If running in non-interactive subshell where alias table is unpopulated, bootstrap it
  if [[ -z "$active_aliases_tmp" ]]; then
    active_aliases_tmp="$(
      shopt -s expand_aliases 2>/dev/null || true
      for f in "${files[@]}"; do [[ -r "$f" ]] && . "$f"; done
      builtin alias -p 2>/dev/null || true
    )"
  fi

  # 2. Collect Git aliases from active git config
  local git_aliases_tmp=""
  if command -v git >/dev/null 2>&1; then
    git_aliases_tmp="$(git config --get-regexp '^alias\.' 2>/dev/null | sort -u || true)"
  fi

  awk -v q="$query" \
      -v active_raw="$active_aliases_tmp" \
      -v git_raw="$git_aliases_tmp" '
  function sort_arr(arr, n,   i, j, temp) {
    for (i = 2; i <= n; i++) {
      temp = arr[i];
      j = i - 1;
      while (j >= 1 && arr[j] > temp) {
        arr[j + 1] = arr[j];
        j--;
      }
      arr[j + 1] = temp;
    }
  }

  function add_cat(c) {
    if (!seen_cat_order[c]++) {
      cat_order[++n_order] = c;
    }
  }

  BEGIN {
    SEP = "\034"; # ASCII Field Separator

    # 1. Parse active shell aliases from OS into active_cmds
    n_active = split(active_raw, a_lines, "\n");
    for (i = 1; i <= n_active; i++) {
      line = a_lines[i];
      if (line ~ /^alias[[:space:]]+/) {
        sub(/^alias[[:space:]]+/, "", line);
        idx = index(line, "=");
        if (idx > 0) {
          c = substr(line, 1, idx - 1);
          rem = substr(line, idx + 1);
          gsub(/^[ \t\047"]+|[ \t\047"]+$/, "", rem);
          if (c != "") {
            active_cmds[c] = rem;
          }
        }
      }
    }

    # Preferred category display order
    add_cat("ENVIRONMENT & RELOAD");
    add_cat("PYTHON VENV");
    add_cat("SYSTEM CONTROL & JOURNAL");
    add_cat("SECURITY & NETWORK CHECK");
    add_cat("PACKAGE MANAGEMENT ALIASES");
    add_cat("PROCESS & SYSTEM MONITORING");
    add_cat("FILE & SYSTEM & NAVIGATION");
    add_cat("DIRECTORY DISK USAGE");
    add_cat("HISTORY SEARCH");
    add_cat("FILE & SYSTEM UTILITIES");
    add_cat("DOCKER & DEVOPS SHORTCUTS");
    add_cat("AI & AGENT CLI HELPERS");
    add_cat("MOBILE DEVELOPMENT HELPERS");
    add_cat("WINDOWS & WSL HELPERS");
    add_cat("WINDOWS POWER & SLEEP MANAGEMENT");
    add_cat("SSH & AGENT MANAGEMENT");
    add_cat("GIT SHORTCUTS & ALIASES");
    add_cat("OS & SHELL ENVIRONMENT");
    add_cat("ECOSYSTEM COMMANDS & UTILITIES");
  }

  # 2. Parse file definitions for category & description metadata
  /^[[:space:]]*#[[:space:]]+[A-Z]/ {
    line = $0;
    sub(/^[[:space:]]*#[[:space:]]+/, "", line);
    sub(/[[:space:]]*\(.*/, "", line);
    # Only treat uppercase titles as category headers
    if (line ~ /^[A-Z0-9 &\/,_-]+$/) {
      curr_cat = line;
      if (curr_cat ~ /SYSTEM CONTROL/) curr_cat = "SYSTEM CONTROL & JOURNAL";
      else if (curr_cat ~ /PACKAGE MANAGEMENT/) curr_cat = "PACKAGE MANAGEMENT ALIASES";
      else if (curr_cat ~ /AI &/) curr_cat = "AI & AGENT CLI HELPERS";
      else if (curr_cat ~ /DOCKER/) curr_cat = "DOCKER & DEVOPS SHORTCUTS";
      else if (curr_cat ~ /MOBILE/) curr_cat = "MOBILE DEVELOPMENT HELPERS";
      else if (curr_cat ~ /DIRECTORY DISK/) curr_cat = "DIRECTORY DISK USAGE";
      else if (curr_cat ~ /HISTORY SEARCH/) curr_cat = "HISTORY SEARCH";
      else if (curr_cat ~ /FILE & SYSTEM UTILITIES/) curr_cat = "FILE & SYSTEM UTILITIES";
      else if (curr_cat ~ /WINDOWS & WSL/) curr_cat = "WINDOWS & WSL HELPERS";
      else if (curr_cat ~ /SSH/) curr_cat = "SSH & AGENT MANAGEMENT";
      add_cat(curr_cat);
    }
    next;
  }

  /^[[:space:]]*alias[[:space:]]+/ {
    line = $0;
    sub(/^[[:space:]]*alias[[:space:]]+/, "", line);
    idx = index(line, "=");
    if (idx > 0) {
      cmd = substr(line, 1, idx - 1);
      rem = substr(line, idx + 1);
      if (match(rem, /[[:space:]]+#[[:space:]]*/)) {
        exp_val = substr(rem, 1, RSTART - 1);
        desc_val = substr(rem, RSTART + RLENGTH);
      } else {
        exp_val = rem;
        desc_val = "";
      }
      gsub(/^[ \t\047"]+|[ \t\047"]+$/, "", exp_val);
      gsub(/^[ \t]+|[ \t]+$/, "", desc_val);
      if (cmd != "" && cat_of[cmd] == "") {
        cat_of[cmd] = (curr_cat != "" ? curr_cat : "GENERAL");
        desc_of[cmd] = desc_val;
        file_exp[cmd] = exp_val;
        add_cat(cat_of[cmd]);
      }
    }
  }

  END {
    # 3. Process active shell aliases
    for (cmd in active_cmds) {
      cat = cat_of[cmd];
      if (cat == "") cat = "OS & SHELL ENVIRONMENT";
      add_cat(cat);
      exp_val = active_cmds[cmd];
      desc_val = desc_of[cmd];

      # Match query
      t = tolower(cat " " cmd " " exp_val " " desc_val);
      if (q != "" && index(t, tolower(q)) == 0) continue;

      items_by_cat[cat, ++items_count[cat]] = cmd SEP exp_val SEP desc_val;
      total_aliases++;
    }

    # 4. Process git aliases
    n_git = split(git_raw, g_lines, "\n");
    for (i = 1; i <= n_git; i++) {
      line = g_lines[i];
      if (line ~ /^alias\./) {
        sub(/^alias\./, "", line);
        idx = index(line, " ");
        if (idx > 0) {
          g_cmd = "git " substr(line, 1, idx - 1);
          g_exp = substr(line, idx + 1);
          if (seen_git[g_cmd]++) continue;
          g_cat = "GIT SHORTCUTS & ALIASES";
          add_cat(g_cat);

          # Match query
          t = tolower(g_cat " " g_cmd " " g_exp);
          if (q != "" && index(t, tolower(q)) == 0) continue;

          items_by_cat[g_cat, ++items_count[g_cat]] = g_cmd SEP g_exp SEP "";
          total_git++;
        }
      }
    }

    # 5. Process Ecosystem Utilities
    u_cat = "ECOSYSTEM COMMANDS & UTILITIES";
    add_cat(u_cat);
    n_u = 0;
    utils[++n_u] = "dirsize" SEP "du -d 1 human sorted" SEP "Directory disk usage breakdown (dus, ds)";
    utils[++n_u] = "h" SEP "history search with limit" SEP "History search helper (h <limit> or h <query>)";
    utils[++n_u] = "psmem" SEP "ps -eo pid,rss,%mem" SEP "Show top processes by memory usage";
    utils[++n_u] = "pscpu" SEP "ps -eo pid,%cpu" SEP "Show top processes by CPU usage";
    utils[++n_u] = "gete" SEP "printenv [key]" SEP "Inspect or search environment variables";
    utils[++n_u] = "clip" SEP "pbcopy | clip.exe | wl-copy" SEP "Cross-platform clipboard copy helper";
    utils[++n_u] = "cpwd" SEP "readlink -f | clip" SEP "Copy Linux path of target (default: PWD) to clipboard";
    utils[++n_u] = "opene" SEP "explorer [path]" SEP "Open file or directory in explorer/file manager";
    utils[++n_u] = "winpath" SEP "wslpath -w [path]" SEP "Convert Unix path to Windows format (WSL)";
    utils[++n_u] = "wcppath" SEP "wslpath -w | clip" SEP "Copy Windows path of target (default: PWD) to clipboard";
    utils[++n_u] = "wcp" SEP "cp <win_path> <linux_path>" SEP "Safe file copying between Windows and Linux";
    utils[++n_u] = "ssha" SEP "ssh-agent & ssh-add" SEP "Start SSH agent & interactively select keys";
    utils[++n_u] = "zen doctor" SEP "system diagnostics" SEP "Authoritative inspection & ecosystem audit";
    utils[++n_u] = "zen sync" SEP "git pull & alias reload" SEP "Pull latest commits & refresh shell aliases";
    utils[++n_u] = "zen ali" SEP "alias catalog" SEP "Browse and search all shell & git shortcuts";
    utils[++n_u] = "zen setup" SEP "modular installer" SEP "Run ZenCLI installation & setup wizard";
    utils[++n_u] = "zen ski" SEP "npx skills [action]" SEP "Agent skills orchestrator (Vercel Skills CLI)";
    utils[++n_u] = "zen skiv" SEP "zen ski venhdev/zenforge" SEP "Personal skills (auto-targets .agents/skills)";
    utils[++n_u] = "zen skiup" SEP "zen ski update -p -y" SEP "Update all project skills according to lockfile";
    utils[++n_u] = "zen sleep" SEP "sleepin [min]" SEP "Put Windows machine to sleep after countdown (default: 30)";
    utils[++n_u] = "sleepin" SEP "zen sleep [min]" SEP "Put Windows machine to sleep after countdown (default: 30)";
    utils[++n_u] = "winsleep" SEP "sleepin [min]" SEP "Put Windows machine to sleep after countdown (default: 30)";

    for (u = 1; u <= n_u; u++) {
      u_row = utils[u];
      split(u_row, u_col, SEP);
      u_name = u_col[1];
      u_exp = u_col[2];
      u_desc = u_col[3];

      t = tolower(u_cat " " u_name " " u_exp " " u_desc);
      if (q != "" && index(t, tolower(q)) == 0) continue;

      items_by_cat[u_cat, ++items_count[u_cat]] = u_name SEP u_exp SEP u_desc;
      total_utils++;
    }

    # 6. Render output by category order
    cg = "\033[1;32m"; cy = "\033[1;33m"; cc = "\033[1;36m";
    cb = "\033[1m"; cgr = "\033[90m"; cr = "\033[0m";

    printf "\n%s%s=== ZENCLI SHORTCUT & ALIAS DIRECTORY ===%s\n", cb, cc, cr;
    if (q != "") {
      printf "%sFiltering shortcuts matching: \047%s\047%s\n\n", cgr, q, cr;
    } else {
      printf "%sLive authoritative registry of all shell aliases and shortcuts in current OS%s\n\n", cgr, cr;
    }

    shown_any = 0;
    for (o = 1; o <= n_order; o++) {
      cat = cat_order[o];
      count = items_count[cat];
      if (count == 0) continue;

      # Sort items alphabetically by command name
      for (k = 1; k <= count; k++) {
        sort_tmp[k] = items_by_cat[cat, k];
      }
      sort_arr(sort_tmp, count);

      printf "%s┌─[ %s ]%s\n", cb, cat, cr;
      for (k = 1; k <= count; k++) {
        split(sort_tmp[k], col, SEP);
        c_name = col[1];
        c_exp = col[2];
        c_desc = col[3];

        if (length(c_exp) > 36) c_exp_disp = substr(c_exp, 1, 33) "...";
        else c_exp_disp = c_exp;

        printf "  %s%-14s%s → %s%-36s%s", cg, c_name, cr, cy, c_exp_disp, cr;
        if (c_desc != "") {
          printf " %s# %s%s", cgr, c_desc, cr;
        }
        printf "\n";
        shown_any = 1;
      }
      printf "\n";
    }

    if (!shown_any) {
      printf "  %s(No aliases or shortcuts found matching query)%s\n\n", cgr, cr;
    } else {
      total = total_aliases + total_git + total_utils;
      printf "%sSummary:%s %d active shortcuts detected (Shell: %d, Git: %d, Utilities: %d)\n\n",
        cb, cr, total, total_aliases, total_git, total_utils;
    }
  }
  ' "${files[@]}"
}
