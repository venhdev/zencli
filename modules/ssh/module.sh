# SSH & AGENT MANAGEMENT

SSH_INIT="${DOTFILES_SSH_INIT:-}"

# Ensure socket directory exists for OpenSSH multiplexing (%C hash avoids macOS 104-byte socket path limit)
if [[ -d "$HOME/.ssh" && ! -d "$HOME/.ssh/sockets" ]]; then
  mkdir -p "$HOME/.ssh/sockets" 2>/dev/null && chmod 700 "$HOME/.ssh/sockets" 2>/dev/null || true
fi

ssha() {
  [[ -z $SSH_AUTH_SOCK ]] && eval "$(ssh-agent -s)" >/dev/null

  local keys=() k
  mapfile -t keys < <(
    find "$HOME/.ssh" -maxdepth 1 -type f \
      \( -name '*_ed25519' -o -name '*_rsa' \) 2>/dev/null
  )

  ((${#keys[@]})) || { echo "No SSH keys found"; return 1; }

  local PS3="SSH key: " COLUMNS=1
  select k in "${keys[@]}"; do
    [[ -n $k ]] && { ssh-add "$k"; return; }
  done
}

if [[ -n $SSH_INIT && -f $SSH_INIT ]]; then
  [[ -z $SSH_AUTH_SOCK ]] && eval "$(ssh-agent -s)" >/dev/null
  ssh-add "$SSH_INIT" &>/dev/null
fi

