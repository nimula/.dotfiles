#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
[ "$(uname)" != "Darwin" ] && exit
source "$(dirname "$0")/utils.sh"

if [ "$SKIP_PKG_INSTALL" = true ]; then
  exit 0
fi

set -Eeuo pipefail

if ! command -v git >/dev/null 2>&1; then
  print_info "git not found. Attempting to install Command Line Tools..."
  run xcode-select --install
fi

if ! type brew >/dev/null 2>/dev/null; then
  print_default "Homebrew not found. Installing Homebrew..."
  run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

run brew update

print_default "Install packages with Homebrew..."
run brew bundle install --file "${CONFIG_DIR}/homebrew/Brewfile"
