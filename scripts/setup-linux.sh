#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
[ "$(uname)" != "Linux" ] && exit
source "$(dirname "$0")/utils.sh"

if [ "$SKIP_PKG_INSTALL" = true ]; then
  exit 0
fi

set -Eeuo pipefail

if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt-get"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
else
  print_error "No supported package manager found (apt-get or yum)." >&2
  exit 1
fi

print_default "Install packages with $PKG_MGR..."
run sudo $PKG_MGR update -yqq
run sudo $PKG_MGR install -yq zsh tmux curl libpam-ssh-agent-auth

# Install RTK.
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh

# Install Herdr.
curl -fsSL https://herdr.dev/install.sh | sh

# Install Codex.
curl -fsSL https://chatgpt.com/codex/install.sh | sh

# Clone Tmux Plugin Manager if it isn't already present.
if [[ ! -d "${HOME}/.tmux/plugins/tpm/" ]]; then
  run git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
fi

# Install yq if it isn't already present.
if ! command -v yq >/dev/null 2>&1; then
  print_default "Installing yq..."
  yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_"

  case "$(uname -m)" in
    x86_64) yq_url+="amd64" ;;
    aarch64) yq_url+="arm64" ;;
    *) print_error "Unsupported architecture: $(uname -m)" && exit 1 ;;
  esac

  dest="/usr/local/bin"
  sudo="sudo"
  # Fallback to ~/.local/bin if /usr/local/bin is not writable or missing
  if [ ! -d "$dest" ]; then
    dest="$HOME/.local/bin"
    sudo=""
    run mkdir -p "$dest"
  fi

  if [ -n "$sudo" ]; then
    run sudo wget "$yq_url" -O "$dest/yq" && run sudo chmod +x "$dest/yq"
  else
    run wget "$yq_url" -O "$dest/yq" && run chmod +x "$dest/yq"
  fi
fi
