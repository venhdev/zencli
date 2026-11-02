#!/usr/bin/env bash
set -e

DIR="${ZENCLI_DIR:-${ZEN_DIR:-${DOTFILES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zencli}}}"
LEGACY_ZEN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zen"
LEGACY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles"
BASHRC="${DOTFILES_BASHRC:-$HOME/.bashrc}"
MANIFEST="$DIR/.installed.json"
[[ -f "$MANIFEST" ]] || MANIFEST="$LEGACY_ZEN_DIR/.installed.json"
[[ -f "$MANIFEST" ]] || MANIFEST="$LEGACY_DIR/.installed.json"

can_prompt_interactively() {
  { exec 3<>/dev/tty; } 2>/dev/null || return 1
  exec 3>&-
}

if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
  CONFIRMED=1
elif can_prompt_interactively; then
  read -rp "Uninstall dotfiles? [y/N] " a </dev/tty
  [[ $a =~ ^[Yy]$ ]] || { echo "Cancelled"; exit; }
else
  read -rp "Uninstall dotfiles? [y/N] " a
  [[ $a =~ ^[Yy]$ ]] || { echo "Cancelled"; exit; }
fi

echo "Uninstalling dotfiles from $DIR..."

# 1. Deterministic rollback using .installed.json if present
if [[ -f "$MANIFEST" ]]; then
  echo "Reading install manifest: $MANIFEST"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, os, shutil, sys

manifest_file = sys.argv[1]
try:
    with open(manifest_file, "r") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

# 1. Restore symlinks / backups
for item in data.get("symlinks", []):
    link = item.get("link")
    backup = item.get("backup")
    if link and os.path.islink(link):
        try:
            os.unlink(link)
            print(f"✔ Removed symlink: {link}")
        except Exception:
            pass
    if backup and os.path.exists(backup) and link:
        try:
            shutil.move(backup, link)
            print(f"✔ Restored backup: {link} from {backup}")
        except Exception:
            pass

# 2. Clean shell hooks
for rc in data.get("shell_hooks", []):
    if os.path.exists(rc):
        with open(rc, "r") as f:
            content = f.read()
        import re
        cleaned = re.sub(r"(?ms)\n*# Load (dotfiles|zen|Zen)\n.*?unset _(cfg|f) (DOTFILES|ZEN)\n*", "", content)
        if cleaned != content:
            with open(rc, "w") as f:
                f.write(cleaned.strip() + "\n")
            print(f"✔ Cleaned shell hook from: {rc}")

# 3. Unset git includes
for git_inc in data.get("git_includes", []):
    os.system(f"git config --global --unset-all include.path \"{git_inc}\" 2>/dev/null")
    print(f"✔ Unset git include: {git_inc}")

# 4. Clean user-installed tools in ~/.local/bin tracked in manifest
local_bin_prefix = os.path.expanduser("~/.local/bin/")
for tool_name, tool_data in data.get("tools", {}).items():
    if tool_data.get("origin") == "github" or tool_data.get("binary_path", "").startswith(local_bin_prefix):
        bin_path = tool_data.get("binary_path")
        if bin_path and os.path.exists(bin_path):
            try:
                os.remove(bin_path)
                print(f"✔ Removed managed tool binary: {bin_path}")
            except Exception:
                pass
' "$MANIFEST"
  fi
fi

# 2. Fallback clean for standard RC if not tracked in manifest
if [[ -f "$BASHRC" ]] && grep -Eq '# Load (dotfiles|zen|zencli|Zen|ZenCLI)' "$BASHRC" 2>/dev/null; then
  sed -i -E '/^# Load (dotfiles|zen|zencli|Zen|ZenCLI)$/,/^unset _(cfg|f) (DOTFILES|ZEN|ZENCLI)$/d' "$BASHRC"
fi

GIT_CONFIG_FILE="$DIR/.gitconfig"
OLD_GIT_ALIASES_FILE="$DIR/.gitconfig_aliases"
if command -v git >/dev/null 2>&1; then
  git config --global --unset-all include.path "$GIT_CONFIG_FILE" 2>/dev/null || true
  git config --global --unset-all include.path "$OLD_GIT_ALIASES_FILE" 2>/dev/null || true
  git config --global --unset-all include.path "$LEGACY_ZEN_DIR/.gitconfig" 2>/dev/null || true
  git config --global --unset-all include.path "$LEGACY_DIR/.gitconfig" 2>/dev/null || true
  git config --global --unset-all include.path "$LEGACY_DIR/.gitconfig_aliases" 2>/dev/null || true
fi

# 3. Clean runtime manifests
rm -f "$MANIFEST" "$DIR/.installed.json.tmp" "$LEGACY_ZEN_DIR/.installed.json" "$LEGACY_DIR/.installed.json" 2>/dev/null || true

# 4. Remove zencli, zen, and legacy repository directories if at standard targets
for d in "$DIR" "$LEGACY_ZEN_DIR" "$LEGACY_DIR"; do
  if [[ -d "$d" && ( "$d" == "${XDG_CONFIG_HOME:-$HOME/.config}/zencli" || "$d" == "${XDG_CONFIG_HOME:-$HOME/.config}/zen" || "$d" == "${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles" ) ]]; then
    rm -rf "$d"
    echo "✔ Removed $d"
  fi
done

echo "Zen uninstalled successfully."
echo
echo "Run below command to reload:"
echo "exec bash"
