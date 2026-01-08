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

# Clone Tmux Plugin Manager if it isn't already present.
if [[ ! -d "${HOME}/.tmux/plugins/tpm/" ]]; then
  run git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
fi
