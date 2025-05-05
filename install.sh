#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
INSTALL_DIR="${INSTALL_DIR:-$HOME/.dotfiles}"

if [ -d "$INSTALL_DIR" ]; then
  echo "Updating dotfiles..."
  git -C "$INSTALL_DIR" pull --rebase --autostash
else
  echo "Cloning dotfiles..."
  git clone https://github.com/nimula/.dotfiles.git "$INSTALL_DIR"
fi

bash "$INSTALL_DIR/scripts/setup.sh" $@
