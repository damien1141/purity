#!/usr/bin/env bash
set -Eeuo pipefail

# Post-install script: optionally clone and run dotfiles installer.
# If declined, remove X autostart entries if present.

USERNAME="${1:-damien}"
HOME_DIR="/home/$USERNAME"

info() { printf '==> %s\n' "$1"; }
warn() { printf 'warn: %s\n' "$1" >&2; }

remove_autostart() {
  info "removing X autostart entries"

  # Fish autostart
  local fish_conf="$HOME_DIR/.config/fish/conf.d/99-autostart-x.fish"
  if [[ -f "$fish_conf" ]]; then
    rm -f "$fish_conf" || warn "failed to remove $fish_conf"
    info "removed $fish_conf"
  fi

  # Bash profile autostart
  local bash_profile="$HOME_DIR/.bash_profile"
  if [[ -f "$bash_profile" ]]; then
    local tmp
    tmp="$(mktemp)"
    grep -v 'exec startx' "$bash_profile" > "$tmp" 2>/dev/null || true
    if [[ -s "$tmp" ]]; then
      mv "$tmp" "$bash_profile" || rm -f "$tmp"
    else
      rm -f "$bash_profile" "$tmp" 2>/dev/null || true
    fi
    info "removed startx autostart from $bash_profile"
  fi
}

main() {
  info "post-install: dotfiles setup"

  read -rp "setup dotfiles now? [Y/n]: " input || input="n"

  if [[ "$input" =~ ^[Nn]$ ]]; then
    info "skipping dotfiles setup"
    remove_autostart
    return 0
  fi

  info "cloning dots repo"
  git clone https://github.com/damien1141/dots.git "$HOME_DIR/dots" || {
    warn "git clone failed"
    remove_autostart
    return 1
  }

  chmod +x "$HOME_DIR/dots/dots.sh" || warn "chmod dots.sh failed"

  info "running dots installer"
  if [[ -x "$HOME_DIR/dots/dots.sh" ]]; then
    sudo -u "$USERNAME" env HOME="$HOME_DIR" XDG_CONFIG_HOME="$HOME_DIR/.config" \
      bash "$HOME_DIR/dots/dots.sh" || warn "dots.sh failed"
  else
    warn "dots.sh not executable"
  fi

  info "post-install complete"
}

main "$@"
