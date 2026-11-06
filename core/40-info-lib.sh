# System info helpers

sysinfo() {
  echo "=== OS Information ==="
  cat /etc/os-release

  echo
  echo "=== Architecture ==="
  uname -m

  echo
  echo "=== Memory Usage ==="
  free -h

  echo
  echo "=== Disk Usage ==="
  df -h
}

envinfo() {
  local probe_timeout_seconds="${ENVINFO_TIMEOUT_SECONDS:-2}"
  local has_timeout=0
  command -v timeout >/dev/null 2>&1 && has_timeout=1

  _envinfo_probe() {
    local cmd="$1"
    local output_file output rc=0 timed_out=0
    local tmp_dir
    if declare -F _get_zen_tmp_dir >/dev/null 2>&1; then
      tmp_dir="$(_get_zen_tmp_dir)"
    else
      tmp_dir="${TMPDIR:-/tmp}/zencli"
      [[ -d "$tmp_dir" ]] || mkdir -p "$tmp_dir" 2>/dev/null || true
    fi
    output_file="$(mktemp "${tmp_dir}/envinfo.XXXXXX")"

    (
      eval "$cmd"
    ) >"$output_file" 2>&1 &
    local probe_pid=$!

    if (( has_timeout )); then
      timeout --foreground "${probe_timeout_seconds}s" bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.05; done' _ "$probe_pid" >/dev/null 2>&1
      if kill -0 "$probe_pid" 2>/dev/null; then
        timed_out=1
      fi
    else
      local deadline=$((SECONDS + probe_timeout_seconds))
      while kill -0 "$probe_pid" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
          timed_out=1
          break
        fi
        sleep 0.05
      done
    fi

    if (( timed_out )); then
      kill "$probe_pid" 2>/dev/null
      sleep 0.1
      kill -9 "$probe_pid" 2>/dev/null
      wait "$probe_pid" 2>/dev/null
      rm -f "$output_file"
      printf 'timeout (%ss)' "$probe_timeout_seconds"
      return 124
    fi

    wait "$probe_pid" 2>/dev/null || rc=$?
    output="$(cat "$output_file")"
    rm -f "$output_file"

    if (( rc != 0 )) || [[ -z "${output//[[:space:]]/}" ]]; then
      printf 'N/A'
      return 1
    fi

    printf '%s' "${output%%$'\n'*}"
  }

  _envinfo_print() {
    local label="$1"
    local cmd="$2"
    printf '%-10s %s\n' "${label}:" "$(_envinfo_probe "$cmd")"
  }

  echo "=== System ==="
  _envinfo_print "OS" "uname -s"
  if [[ -n "${_LINUX_DISTRO:-}" && "$_LINUX_DISTRO" != "unknown" ]]; then
    _envinfo_print "Distro" "printf '%s' '$_LINUX_DISTRO'"
  fi
  _envinfo_print "Kernel" "uname -r"
  _envinfo_print "Arch" "uname -m"
  if is_wsl 2>/dev/null || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    _envinfo_print "WSL Path" "awk -F'=' '/^[[:space:]]*appendWindowsPath[[:space:]]*=/ {gsub(/[[:space:]]/, \"\", \$2); val=tolower(\$2)} END {if (val==\"false\") print \"appendWindowsPath = false\"; else if (val==\"true\") print \"appendWindowsPath = true\"; else print \"appendWindowsPath = default/true\"}' /etc/wsl.conf 2>/dev/null || printf 'appendWindowsPath = default/true'"
  fi
  if (( has_timeout )); then
    _envinfo_print "Probe TTL" "printf 'timeout ${probe_timeout_seconds}s'"
  else
    _envinfo_print "Probe TTL" "printf 'fallback ${probe_timeout_seconds}s (timeout command not found)'"
  fi

  echo
  echo "=== Node ==="
  _envinfo_print "Node" "node -v"
  _envinfo_print "npm" "npm -v"
  _envinfo_print "pnpm" "pnpm -v"
  _envinfo_print "yarn" "yarn -v"
  _envinfo_print "nvm" "command -v nvm >/dev/null 2>&1 && nvm --version"

  echo
  echo "=== Languages ==="
  _envinfo_print "Python" "python3 --version"
  _envinfo_print "Go" "go version"
  _envinfo_print "Java" "java -version"

  echo
  echo "=== Search & Navigation ==="
  _envinfo_print "rg" "rg --version"
  if command -v fd >/dev/null 2>&1; then
    _envinfo_print "fd" "fd --version"
  else
    _envinfo_print "fdfind" "fdfind --version"
  fi
  _envinfo_print "ast-grep" "ast-grep --version"
  _envinfo_print "git grep" "git --version"

  echo
  echo "=== File Viewing & Listing ==="
  if command -v bat >/dev/null 2>&1; then
    _envinfo_print "bat" "bat --version"
  else
    _envinfo_print "batcat" "batcat --version"
  fi
  _envinfo_print "eza" "eza --version"

  echo
  echo "=== Data & APIs ==="
  _envinfo_print "jq" "jq --version"
  _envinfo_print "yq" "yq --version"
  _envinfo_print "sd" "sd --version"
  _envinfo_print "curl" "curl --version"

  echo
  echo "=== Version Control & Workflow ==="
  _envinfo_print "git" "git --version"
  _envinfo_print "gh" "gh --version"
  _envinfo_print "delta" "delta --version"
  _envinfo_print "hyperfine" "hyperfine --version"

  echo
  echo "=== Containers & Infra ==="
  _envinfo_print "docker" "docker --version"
  _envinfo_print "compose" "docker compose version"
  _envinfo_print "kubectl" "kubectl version --client=true"

  echo
  echo "=== Editors / Other ==="
  _envinfo_print "VSCode" "code --version"
}
