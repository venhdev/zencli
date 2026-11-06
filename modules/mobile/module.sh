# MOBILE DEVELOPMENT HELPERS

# --- Android keystore helpers ---

alias debugkey='keytool -list -v -keystore "${HOME}/.android/debug.keystore" -alias androiddebugkey -storepass android -keypass android' # Print Android debug keystore SHA fingerprints

# --- ADB helpers ---

_adb_devices() {
  adb devices -l | awk '
    NR>1 && NF {
      m="?"
      for(i=3;i<=NF;i++)
        if($i~/^model:/) { m=substr($i,7); break }
      print $1 "\t" $2 "\t" m
    }'
}

_adb_model() {
  _adb_devices |
    awk -F'\t' -v s="$1" '$1==s {print $3; exit}'
}

_adb_pick_devices() {
  local items=() picked s state model

  while IFS=$'\t' read -r s state model; do
    [[ $state == device ]] && items+=("$s | $model")
  done < <(_adb_devices)

  mapfile -t picked < <(_pick_many "📱 Select device(s):" "${items[@]}")

  for s in "${picked[@]}"; do
    echo "${s%% | *}"
  done
}

# _adb_apk_scope <root_var> <filter_var> [arg] [filter]
# First arg is treated as a directory when it exists, otherwise as a filter.
_adb_apk_scope() {
  local -n _root_ref="$1" _filter_ref="$2"
  _root_ref="."
  _filter_ref=""
  if [[ -n "${3:-}" ]]; then
    if [[ -d "$3" ]]; then
      _root_ref="$3"
      _filter_ref="${4:-}"
    else
      _filter_ref="$3"
    fi
  fi
}

# _adb_find_apks <root_dir> [filter]
_adb_find_apks() {
  local root_dir="${1:-.}" filter="${2:-}" f
  while IFS= read -r f; do
    [[ -n $f && ( -z $filter || $f == *"$filter"* ) ]] && printf '%s\n' "$f"
  done < <(
    find "$root_dir" -not -path '*/.*' -type f -name "*.apk" -printf '%T@ %p\n' 2>/dev/null |
      sort -nr |
      cut -d' ' -f2-
  )
}

_adb_pick_apks() {
  local root_dir filter apks=()
  _adb_apk_scope root_dir filter "${1:-}" "${2:-}"
  mapfile -t apks < <(_adb_find_apks "$root_dir" "$filter")
  _pick_many "📦 Select APK(s):" "${apks[@]}"
}

# lsapk [dir] [filter] - list APK files, newest first
lsapk() {
  local root_dir filter apks=()
  _adb_apk_scope root_dir filter "${1:-}" "${2:-}"
  mapfile -t apks < <(_adb_find_apks "$root_dir" "$filter")

  ((${#apks[@]})) || {
    echo "❌ No APK found" >&2
    return 1
  }

  printf '%s\n' "${apks[@]}"
}

adbls() {
  while IFS=$'\t' read -r s state model; do
    printf "%-24s %-8s %s\n" "$s" "$state" "$model"
  done < <(_adb_devices)
}

adbid() {
  local targets apks t apk m ok=0 fail=0

  mapfile -t targets < <(_adb_pick_devices)
  ((${#targets[@]})) || { echo "❌ No device"; return 1; }

  mapfile -t apks < <(_adb_pick_apks "${1:-}" "${2:-}")
  ((${#apks[@]})) || { echo "❌ No APK"; return 1; }

  for t in "${targets[@]}"; do
    m=$(_adb_model "$t")
    printf '\n▶ %s | %s\n' "$t" "$m"
    for apk in "${apks[@]}"; do
      _print_cmdline adb -s "$t" install -r "$apk"
    done
  done

  _confirm || { echo "✗ cancelled"; return 1; }

  for t in "${targets[@]}"; do
    m=$(_adb_model "$t")
    echo "── $t | $m ──"

    for apk in "${apks[@]}"; do
      _log_cmd adb -s "$t" install -r "$apk"
      adb -s "$t" install -r "$apk" &&
        ((++ok)) || ((++fail))
    done
  done

  echo
  echo "✅ $ok ok, ❌ $fail failed"
  ((fail == 0))
}

# Flutter web browser integration
if declare -F _get_zen_root >/dev/null 2>&1; then
  _dotfiles_root="$(_get_zen_root)"
elif declare -F _get_dotfiles_root >/dev/null 2>&1; then
  _dotfiles_root="$(_get_dotfiles_root)"
else
  _dotfiles_root="${ZENCLI_ROOT:-${ZENCLI_DIR:-${ZENCLI:-${DOTFILES:-${XDG_CONFIG_HOME:-$HOME/.config}/zencli}}}}"
  [[ -d "$_dotfiles_root" ]] || _dotfiles_root="$HOME/.config/zencli"
fi
_chrome_wrapper="$_dotfiles_root/modules/mobile/chrome-wrapper.sh"

if [[ -z "${CHROME_EXECUTABLE:-}" ]]; then
  for _c in \
    "${DOTFILES_CHROME_EXECUTABLE:-}" \
    "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
    "/mnt/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
    "$HOME/.local/bin/chrome"; do
    if [[ -n "$_c" && -x "$_c" ]]; then
      export CHROME_EXECUTABLE="$_c"
      break
    fi
  done
  unset _c
fi

# WSL: Flutter runs as Linux but CHROME_EXECUTABLE may point at a Windows .exe.
# Flutter runs `<chrome> --version` during device discovery, which Windows
# Chrome handles by launching a browser window instead of printing a version.
# Route it through a small wrapper so `flr`/`flutter devices` do not pop Chrome.
if [[ -n "${CHROME_EXECUTABLE:-}" && -x "$_chrome_wrapper" && "$CHROME_EXECUTABLE" != "$_chrome_wrapper" ]]; then
  _chrome_real="$(readlink -f "$CHROME_EXECUTABLE" 2>/dev/null || printf '%s' "$CHROME_EXECUTABLE")"
  if [[ "${_chrome_real,,}" == *.exe ]]; then
    export DOTFILES_CHROME_EXECUTABLE="$_chrome_real"
    export CHROME_EXECUTABLE="$_chrome_wrapper"
  fi
  unset _chrome_real
fi

unset _dotfiles_root _chrome_wrapper

# --- Flutter helpers ---

_flutter_runner() {
  if command -v fvm &>/dev/null && [[ -f .fvmrc || -d .fvm ]]; then
    echo "fvm flutter"
  else
    echo "flutter"
  fi
}

_flutter_devices() {
  $(_flutter_runner) devices --machine |
    jq -r '.[] | [.id, .name] | @tsv'
}

_flutter_pick_device() {
  local items=() id name picked

  while IFS=$'\t' read -r id name; do
    items+=("$name | $id")
  done < <(_flutter_devices)

  picked=$(_pick_one "Device: " "${items[@]}") || return
  echo "${picked##* | }"
}

_flutter_flavors() {
  local file

  for file in android/app/build.gradle android/app/build.gradle.kts; do
    [[ -f $file ]] || continue

    awk '
      /productFlavors[[:space:]]*\{/ { on=1; depth=1; next }

      on {
        line=$0

        if(depth==1) {
          s=line
          sub(/^[[:space:]]*/, "", s)

          if(s ~ /^create\("[^"]+"\)/) {
            sub(/^create\("/, "", s)
            sub(/".*/, "", s)
            print s
          }
          else if(s ~ /^[A-Za-z0-9_]+[[:space:]]*\{/) {
            sub(/[[:space:]]*\{.*/, "", s)
            print s
          }
        }

        o=gsub(/\{/,"{",line)
        c=gsub(/\}/,"}",line)
        depth+=o-c

        if(depth<=0) exit
      }
    ' "$file"

    return
  done
}

_flutter_pick_flavor() {
  local flavors=() f
  mapfile -t flavors < <(_flutter_flavors)

  if ((${#flavors[@]})); then
    f=$(_pick_one "Flavor: " "${flavors[@]}" skip) || return
    [[ $f != skip ]] && echo "$f"
  else
    echo "No flavor detected, skipping." >&2
  fi

  return 0
}

_flutter_pick_mode() {
  local PS3="Mode: " mode

  _prompt_gap
  select mode in debug profile release; do
    echo "${mode:-debug}"
    return
  done
}

# Default to keeping the full icon font: a tree-shaken icon font differs between
# builds, which shows up as an asset diff in diffing tools (e.g. Shorebird patch).
_flutter_icon_args() {
  local -n out="$1"

  if _confirm "no-tree-shake-icons? [Y/n] "; then
    out+=(--no-tree-shake-icons)
  fi
}

_flutter_find_env_candidates() {
  local dir f candidates=()
  local search_dirs=("." "env" "assets/env" "config" "config/env")

  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/.env* "$dir"/*.env*; do
      [[ -f "$f" ]] || continue
      case "$(basename "$f")" in
        *.example*|*.sample*|*.template*|*.bak|*.swp|*.tmp|*.default*) continue ;;
      esac
      f="${f#./}"
      candidates+=("$f")
    done
  done

  for f in "${candidates[@]}"; do
    echo "$f"
  done | awk '!seen[$0]++'
}

_flutter_pick_env() {
  local flavor="${1:-}" default_env=""
  local candidates=() f choice

  mapfile -t candidates < <(_flutter_find_env_candidates)

  if [[ -n $flavor ]]; then
    local fl_lower="${flavor,,}"
    for f in "${candidates[@]}"; do
      if [[ "$(basename "$f")" == ".env.$flavor" || "$(basename "$f")" == ".env.$fl_lower" ]]; then
        default_env="$f"
        break
      fi
    done
    if [[ -z $default_env ]]; then
      for f in "${candidates[@]}"; do
        if [[ "$(basename "$f")" == *"$fl_lower"* ]]; then
          default_env="$f"
          break
        fi
      done
    fi
  fi

  if [[ -z $default_env ]]; then
    for f in "${candidates[@]}"; do
      if [[ "$f" == ".env" || "$(basename "$f")" == ".env" ]]; then
        default_env="$f"
        break
      fi
    done
  fi

  if [[ -z $default_env && ${#candidates[@]} -gt 0 ]]; then
    default_env="${candidates[0]}"
  fi

  if ((${#candidates[@]} == 0)); then
    _prompt_gap
    read -rp "dart-define-from-file (skip=Enter): " choice
    echo "$choice"
    return 0
  fi

  _prompt_gap
  echo "Env file:" >&2
  local i
  for i in "${!candidates[@]}"; do
    if [[ "${candidates[i]}" == "$default_env" ]]; then
      printf "  %d) %s (default)\n" "$((i + 1))" "${candidates[i]}" >&2
    else
      printf "  %d) %s\n" "$((i + 1))" "${candidates[i]}" >&2
    fi
  done
  printf "  s) Skip\n" >&2

  local prompt="Select env file (1-${#candidates[@]}, Enter=${default_env:-skip}, s=skip): "
  [[ -z $default_env ]] && prompt="Select env file (1-${#candidates[@]}, Enter=skip, s=skip): "

  read -rp "$prompt" choice || return 1
  choice="${choice:-$default_env}"

  case "$choice" in
    s|S|skip|SKIP|none|NONE)
      echo ""
      return 0
      ;;
    "")
      echo ""
      return 0
      ;;
  esac

  if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#candidates[@]})); then
    echo "${candidates[choice - 1]}"
    return 0
  fi

  for f in "${candidates[@]}"; do
    if [[ "$choice" == "$f" ]]; then
      echo "$f"
      return 0
    fi
  done

  if [[ -f "$choice" ]]; then
    echo "$choice"
    return 0
  fi

  echo "❌ File not found: $choice" >&2
  return 1
}

_flutter_args() {
  local -n out="$1"
  local platform="${2:-}"
  local envfile flavor mode

  if [[ $platform != web ]]; then
    flavor=$(_flutter_pick_flavor) || return
    [[ -n $flavor ]] && out+=(--flavor="$flavor")
  fi

  envfile=$(_flutter_pick_env "$flavor") || return
  [[ -n $envfile ]] && out+=(--dart-define-from-file="$envfile")

  mode=$(_flutter_pick_mode) || return
  out+=("--$mode")
}

_flutter_pick_platform() {
  local items=(
    "android-apk"
    "android aab"
    "ios (comming soon)"
    "web"
  )
  local choice i

  _prompt_gap
  echo "Platform:" >&2
  for i in "${!items[@]}"; do
    if ((i == 0)); then
      printf '  %d) %s (default)\n' "$((i+1))" "${items[i]}" >&2
    else
      printf '  %d) %s\n' "$((i+1))" "${items[i]}" >&2
    fi
  done

  while true; do
    read -rp "Select platform (1-4, Enter=1): " choice || return 1
    choice="${choice:-1}"

    case "$choice" in
      1|"android-apk"|"apk"|"android apk")
        echo "apk"
        return 0
        ;;
      2|"android aab"|"aab"|"appbundle"|"android-aab")
        echo "appbundle"
        return 0
        ;;
      3|"ios"|"ios (comming soon)"|"ios (coming soon)")
        echo "❌ ios is disabled (comming soon)" >&2
        _prompt_gap
        ;;
      4|"web")
        echo "web"
        return 0
        ;;
      *)
        echo "❌ Invalid platform: $choice" >&2
        _prompt_gap
        ;;
    esac
  done
}

_flutter_pick_target() {
  [[ -d lib ]] || return 0
  local f files=() other=0

  for f in lib/*main*.dart; do
    [[ -f $f ]] || continue
    files+=("$f")
    [[ $f != "lib/main.dart" ]] && other=1
  done

  ((other)) || return 0

  local targets=()
  [[ -f lib/main.dart ]] && targets+=("lib/main.dart")
  for f in "${files[@]}"; do
    [[ $f != "lib/main.dart" ]] && targets+=("$f")
  done

  ((${#targets[@]})) || return 0

  local def="${targets[0]}" choice i
  _prompt_gap
  echo "Target:" >&2
  for i in "${!targets[@]}"; do
    if [[ ${targets[i]} == "$def" ]]; then
      printf '  %d) %s (default)\n' "$((i+1))" "${targets[i]}" >&2
    else
      printf '  %d) %s\n' "$((i+1))" "${targets[i]}" >&2
    fi
  done

  while true; do
    read -rp "Select target (1-${#targets[@]}, Enter=$def): " choice || return 1
    choice="${choice:-1}"

    if [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#targets[@]})); then
      echo "${targets[choice-1]}"
      return 0
    fi

    for f in "${targets[@]}"; do
      if [[ $choice == "$f" || $choice == "${f#lib/}" ]]; then
        echo "$f"
        return 0
      fi
    done

    echo "❌ Invalid target: $choice" >&2
    _prompt_gap
  done
}

_flutter_app_name() {
  local name=""
  if [[ -f pubspec.yaml ]]; then
    name=$(awk '/^[[:space:]]*name:[[:space:]]*/ { sub(/^[[:space:]]*name:[[:space:]]*/, ""); gsub(/[[:space:]"\x27]/, ""); print; exit }' pubspec.yaml 2>/dev/null)
  fi
  echo "${name:-$(basename "$PWD")}"
}

_flutter_pick_log_file() {
  local app_name
  app_name="$(_flutter_app_name)"
  local date_str
  date_str="$(date '+%Y%m%d-%H%M%S')"
  local default_log="/tmp/flutter-run-${app_name}-${date_str}.log"

  _prompt_gap
  echo "Log file:" >&2
  printf "  1) None (default - do not tee to file)\n" >&2
  printf "  2) Auto: %s\n" "$default_log" >&2
  printf "  c) Custom file path\n" >&2

  local choice
  read -rp "Log output (1-2/c, Enter=1): " choice || return 1
  choice="${choice:-1}"

  case "$choice" in
    1|n|N|none|NONE)
      echo ""
      return 0
      ;;
    2|a|A|auto|AUTO)
      echo "$default_log"
      return 0
      ;;
    c|C|custom)
      read -rp "Enter log file path: " choice
      echo "$choice"
      return 0
      ;;
    *)
      echo "$choice"
      return 0
      ;;
  esac
}

flr() {
  local device args=() cmd log_file

  device=$(_flutter_pick_device) ||
    { echo "❌ No device"; return 1; }

  _flutter_args args || return

  log_file=$(_flutter_pick_log_file) || return

  cmd=($(_flutter_runner) run -d "$device" "${args[@]}")
  if [[ -n "$log_file" ]]; then
    local cmd_str
    cmd_str="$(_format_cmdline "${cmd[@]}") 2>&1 | tee \"$log_file\""
    _run_confirm eval "$cmd_str"
  else
    _run_confirm "${cmd[@]}"
  fi
}

flb() {
  local platform="${1:-}" target args=() cmd

  case "$platform" in
    apk|"android-apk"|"android apk") platform="apk" ;;
    aab|"android aab"|"android-aab"|appbundle) platform="appbundle" ;;
    web) platform="web" ;;
    ios*|"ios (comming soon)"|"ios (coming soon)")
      echo "❌ ios is disabled (comming soon)" >&2
      return 1
      ;;
    "")
      platform=$(_flutter_pick_platform) || return
      ;;
    *)
      echo "❌ Unknown platform: $platform (choose apk, aab, or web)" >&2
      return 1
      ;;
  esac

  target=$(_flutter_pick_target) || return
  [[ -n $target ]] && args+=(-t "$target")

  _flutter_icon_args args || return
  _flutter_args args "$platform" || return

  cmd=($(_flutter_runner) build "$platform" "${args[@]}")
  _run_confirm "${cmd[@]}"
}

# --- Shorebird helpers ---

_shorebird_preflight() {
  command -v shorebird &>/dev/null || {
    echo "❌ shorebird not found" >&2
    return 1
  }

  [[ -f shorebird.yaml ]] || {
    echo "❌ shorebird.yaml not found (run: shorebird init)" >&2
    return 1
  }

  [[ -f pubspec.yaml ]] || {
    echo "❌ pubspec.yaml not found (run at project root)" >&2
    return 1
  }
}

# Top-level `version:` only, so `version:` under dependencies never matches.
_shorebird_version() {
  awk '
    /^version:[[:space:]]*/ {
      sub(/^version:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*/, "")
      gsub(/[[:space:]"]/, "")
      print
      exit
    }
  ' pubspec.yaml
}

# _shorebird_pick <label> <default> <option>...
_shorebird_pick() {
  local label="$1" def="$2" v opt
  shift 2

  _prompt_gap
  read -rp "$label ($*, Enter=$def): " v
  v="${v:-$def}"

  for opt in "$@"; do
    [[ $v == "$opt" ]] && { echo "$v"; return; }
  done

  echo "❌ $label must be: $* (received: $v)" >&2
  return 1
}

_shorebird_dart_args() {
  local -n out="$1"
  local flavor="$2" envfile

  envfile=$(_flutter_pick_env "$flavor") || return
  [[ -n $envfile ]] && out+=(--dart-define-from-file="$envfile")
  return 0
}

_flsb_release() {
  local dry_run=0
  local artifact current flavor
  local cmd=() args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) dry_run=1; shift ;;
      *) break ;;
    esac
  done

  _shorebird_preflight || return
  command -v fvm &>/dev/null || {
    echo "❌ fvm not found (required for --flutter-version=fvm)" >&2
    return 1
  }

  current=$(_shorebird_version)
  [[ -n $current ]] || {
    echo "❌ version: not found in pubspec.yaml" >&2
    return 1
  }
  echo "Version: $current"

  artifact=$(_shorebird_pick Artifact apk aab apk) || return
  flavor=$(_flutter_pick_flavor) || return
  _flutter_icon_args args || return

  cmd=(shorebird release android --flutter-version=fvm --artifact "$artifact")
  ((dry_run)) && cmd+=(--dry-run)
  [[ -n $flavor ]] && cmd+=(--flavor "$flavor")

  _shorebird_dart_args args "$flavor" || return
  cmd+=(-- "${args[@]}")

  _run_confirm "${cmd[@]}"
}

_flsb_patch() {
  local dry_run=0
  local track current flavor
  local cmd=() args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) dry_run=1; shift ;;
      *) break ;;
    esac
  done

  _shorebird_preflight || return

  current=$(_shorebird_version)
  [[ -n $current ]] || {
    echo "❌ version: not found in pubspec.yaml" >&2
    return 1
  }

  track=$(_shorebird_pick Track staging staging stable) || return
  flavor=$(_flutter_pick_flavor) || return
  _flutter_icon_args args || return

  cmd=(shorebird patch android --track "$track" --release-version "$current")
  ((dry_run)) && cmd+=(--dry-run)
  [[ -n $flavor ]] && cmd+=(--flavor "$flavor")

  _shorebird_dart_args args "$flavor" || return
  cmd+=(-- "${args[@]}")

  _run_confirm "${cmd[@]}"
}

_flsb_help() {
  cat <<'EOF'
flsb - Flutter Shorebird helper

Usage:
  flsb <command> [options]

Commands:
  release, r [-n|--dry-run]   Release Android app via Shorebird & FVM
  patch, p   [-n|--dry-run]   Patch Android app via Shorebird
  preview                     Preview releases/patches (shorebird preview)
  doctor                      Check Shorebird and environment
  help, -h                    Show this help message
  <any>                       Forward directly to shorebird CLI

Options:
  -n, --dry-run               Run build without uploading/submitting

Shortcuts:
  sbr                         Shortcut for 'flsb release'
  sbp                         Shortcut for 'flsb patch'
  sb                          Shortcut for 'flsb'
EOF
}

flsb() {
  local subcmd="${1:-}"
  case "$subcmd" in
    release|r)
      shift
      _flsb_release "$@"
      ;;
    patch|p)
      shift
      _flsb_patch "$@"
      ;;
    preview)
      shift
      _shorebird_preflight || return
      shorebird preview "$@"
      ;;
    doctor)
      shift
      command -v shorebird &>/dev/null || {
        echo "❌ shorebird not found" >&2
        return 1
      }
      shorebird doctor "$@"
      ;;
    help|-h|--help|"")
      _flsb_help
      ;;
    *)
      command -v shorebird &>/dev/null || {
        echo "❌ shorebird not found" >&2
        return 1
      }
      shorebird "$@"
      ;;
  esac
}

sbr() { flsb release "$@"; }
sbp() { flsb patch "$@"; }

if [[ -n "${BASH_VERSION:-}" ]] && command -v complete &>/dev/null; then
  _flsb_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    if [[ $COMP_CWORD -eq 1 ]]; then
      COMPREPLY=($(compgen -W "release patch preview doctor help" -- "$cur"))
    elif [[ "$prev" == "release" || "$prev" == "patch" || "$prev" == "r" || "$prev" == "p" ]]; then
      COMPREPLY=($(compgen -W "-n --dry-run" -- "$cur"))
    fi
  }
  complete -F _flsb_completions flsb 2>/dev/null || true
fi
